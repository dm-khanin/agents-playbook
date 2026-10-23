"""Tests for lib/pgcheck.py: one read statement, split the way PostgreSQL splits it."""

import subprocess
import sys
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB))

from pgcheck import Refused, check  # noqa: E402


class Passes(unittest.TestCase):
    def assertPasses(self, sql, mode="cursor", statement=None):
        got_mode, got_statement = check(sql)
        self.assertEqual(got_mode, mode, sql)
        if statement is not None:
            self.assertEqual(got_statement, statement)

    def test_read_statements_and_their_modes(self):
        self.assertPasses("SELECT 1")
        self.assertPasses("with x as (select 1) select * from x")
        self.assertPasses("VALUES (1), (2)")
        self.assertPasses("TABLE accounts")
        self.assertPasses("(SELECT 1) UNION (SELECT 2)")
        self.assertPasses("EXPLAIN ANALYZE SELECT 1", mode="direct")
        self.assertPasses("show statement_timeout", mode="direct")

    def test_one_trailing_semicolon_is_dropped_with_what_follows_it(self):
        self.assertPasses("SELECT 1;", statement="SELECT 1")
        self.assertPasses("SELECT 1 ;  -- done\n", statement="SELECT 1")
        self.assertPasses("SELECT 1; /* done */", statement="SELECT 1")

    def test_leading_comments_are_fine(self):
        self.assertPasses("-- why\nSELECT 1")
        self.assertPasses("/* why */ SELECT 1")

    def test_semicolons_inside_strings_identifiers_and_comments_are_text(self):
        self.assertPasses("SELECT ';' AS a")
        self.assertPasses("SELECT 'it''s; fine' AS a")
        self.assertPasses("SELECT E'\\'; still a string' AS a")
        self.assertPasses("SELECT $$ ; $$ AS a, $tag$ ; ' $tag$ AS b")
        self.assertPasses('SELECT 1 AS "a;b"')
        self.assertPasses('SELECT 1 AS "say ""hi"";"')
        self.assertPasses("SELECT 1 -- ; \n")
        self.assertPasses("SELECT 1 /* ; /* nested ; */ still ; */")

    def test_bit_hex_and_national_strings(self):
        self.assertPasses("SELECT B'1010', X'1F', N'abc;'")

    def test_words_that_only_look_like_writes(self):
        self.assertPasses("SELECT relname FROM pg_class WHERE relname = 'vacuum'")
        self.assertPasses("SELECT * FROM notes WHERE body LIKE '%delete%'")
        self.assertPasses("SELECT updated_at, created_by FROM update_log")

    def test_denied_names_inside_strings_and_comments_are_text(self):
        self.assertPasses("SELECT 'pg_terminate_backend' AS name")
        self.assertPasses("SELECT 1 -- pg_reload_conf()\n")
        self.assertPasses("SELECT 1 /* dblink */")

    def test_a_function_that_only_contains_a_denied_name_passes(self):
        self.assertPasses("SELECT my_pg_terminate_backend_log(1)")
        self.assertPasses("SELECT read_my_file('x')")

    def test_parameters_and_dollar_identifiers_are_not_dollar_quotes(self):
        self.assertPasses("SELECT $1, a$b$ FROM t")

    def test_unicode_identifiers(self):
        self.assertPasses("SELECT имя FROM таблица")

    def test_u_followed_by_ampersand_in_a_string_is_not_an_escape(self):
        self.assertPasses("SELECT 'menu&' AS label")


class Refusals(unittest.TestCase):
    def assertRefused(self, sql, reason):
        with self.assertRaises(Refused) as caught:
            check(sql)
        self.assertEqual(str(caught.exception), reason, sql)

    def test_writes_and_other_statements(self):
        for sql in ("UPDATE t SET a = 1", "DELETE FROM t", "INSERT INTO t VALUES (1)", "DROP TABLE t",
                    "CREATE TABLE t (a int)", "COPY t TO STDOUT", "CALL p()", "DO $$ BEGIN END $$",
                    "BEGIN", "COMMIT", "SET ROLE admin", "VACUUM t", '"select" 1', "+ 1"):
            self.assertRefused(sql, "not-a-read-statement")

    def test_a_second_statement(self):
        self.assertRefused("SELECT 1; SELECT 2", "multi-statement")
        self.assertRefused("SELECT 1; COMMIT", "multi-statement")
        self.assertRefused("SELECT 1;;", "multi-statement")
        self.assertRefused("SELECT 1; 'x'", "multi-statement")

    def test_an_e_string_escape_cannot_hide_a_second_statement(self):
        # Without the E, \' ends the string and the ; is code; with it, the whole tail is one string.
        self.assertRefused("SELECT '\\'; DELETE FROM t; --'", "multi-statement")
        self.assertEqual(check("SELECT E'\\'; DELETE FROM t; --'")[0], "cursor")

    def test_anything_left_open(self):
        self.assertRefused("SELECT 'abc", "unterminated-string")
        self.assertRefused("SELECT E'abc\\'", "unterminated-string")
        self.assertRefused('SELECT "abc', "unterminated-identifier")
        self.assertRefused("SELECT 1 /* open", "unterminated-comment")
        self.assertRefused("SELECT 1 /* /* nested */", "unterminated-comment")
        self.assertRefused("SELECT $a$ x", "unterminated-dollar-quote")

    def test_unicode_escapes(self):
        self.assertRefused('SELECT U&"pg_reload\\005fconf"()', "unicode-escape-refused")
        self.assertRefused("SELECT u&'\\0041'", "unicode-escape-refused")

    def test_empty(self):
        for sql in ("", "   ", ";", "-- only a comment\n", "/* */"):
            self.assertRefused(sql, "empty-statement")

    def test_denied_functions_however_they_are_written(self):
        cases = {
            "SELECT pg_terminate_backend(1)": "pg_terminate_backend",
            "SELECT pg_catalog.pg_terminate_backend(pid) FROM pg_stat_activity": "pg_terminate_backend",
            'SELECT "pg_reload_conf"()': "pg_reload_conf",
            "SELECT PG_RELOAD_CONF()": "pg_reload_conf",
            "SELECT pg_reload_conf/**/()": "pg_reload_conf",
            "SELECT pg_reload_conf -- x\n()": "pg_reload_conf",
            "SELECT pg_cancel_backend(1)": "pg_cancel_backend",
            "SELECT pg_read_file('/etc/passwd')": "pg_read_file",
            "SELECT pg_read_binary_file('x')": "pg_read_binary_file",
            "SELECT * FROM pg_ls_waldir()": "pg_ls_waldir",
            "SELECT lo_export(1, '/tmp/x')": "lo_export",
            "SELECT pg_stat_reset_shared('bgwriter')": "pg_stat_reset_shared",
            "SELECT pg_stat_statements_reset()": "pg_stat_statements_reset",
            "SELECT pg_create_logical_replication_slot('s', 'p')": "pg_create_logical_replication_slot",
            "SELECT * FROM pg_logical_slot_get_changes('s', NULL, NULL)": "pg_logical_slot_get_changes",
            "SELECT pg_switch_wal()": "pg_switch_wal",
            "SELECT * FROM dblink('host=x', 'select 1') AS t(a int)": "dblink",
            "SELECT dblink_exec('x', 'delete')": "dblink_exec",
            "SELECT query_to_xml('SELECT pg_' || 'reload_conf()', true, false, '')": "query_to_xml",
            "SELECT * FROM ts_stat('SELECT v FROM docs')": "ts_stat",
        }
        for sql, name in cases.items():
            self.assertRefused(sql, f"denied-function: {name}")


class Cli(unittest.TestCase):
    def run_cli(self, sql):
        return subprocess.run([sys.executable, "-I", str(LIB / "pgcheck.py")], input=sql,
                              capture_output=True, text=True)

    def test_pass_prints_mode_then_statement(self):
        done = self.run_cli("SELECT 1,\n  2;\n")
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout, "cursor\nSELECT 1,\n  2\n")

    def test_refusal_prints_the_reason_and_exits_1(self):
        done = self.run_cli("SELECT 1; SELECT 2")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(done.stdout, "multi-statement\n")


if __name__ == "__main__":
    unittest.main()
