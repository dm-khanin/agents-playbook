"""Tests for lib/jsblank.py: literals and comments blanked, code kept."""

import subprocess
import sys
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB))

from jsblank import Unterminated, blank  # noqa: E402


class Blanks(unittest.TestCase):
    def assertBlanked(self, code, expected):
        """expected is the code with every blanked character written as an underscore."""
        got = blank(code)
        self.assertEqual(len(got), len(code), code)
        self.assertEqual(got, expected.replace("_", " "), code)

    def test_strings_keep_their_quotes_and_lose_their_contents(self):
        self.assertBlanked("f('a;b', \"c[d]\")", "f('___', \"____\")")

    def test_escaped_quotes_stay_inside_the_string(self):
        self.assertBlanked(r"f('it\'s; x', 1)", "f('________', 1)")

    def test_comments_are_blanked_and_a_line_comment_keeps_its_newline(self):
        self.assertBlanked("a /* ; */ b // ; x\nc", "a _______ b ______\nc")

    def test_regular_expressions_after_an_operator_are_blanked(self):
        self.assertBlanked("f({e: /x[;]y/i})", "f({e: /_______})")
        self.assertBlanked("f(/[/]/)", "f(/____)")

    def test_a_slash_after_an_operand_is_division(self):
        for code in ("a / b / c", "f(x) / 2 / g(y)", "arr[0] / n", "({}/db.c(1)/1)"):
            self.assertEqual(blank(code), code)

    def test_a_slash_after_a_keyword_starts_a_regular_expression(self):
        self.assertBlanked("d => { return /;/.test(d) }", "d => { return /__.test(d) }")

    def test_template_text_is_blanked_and_its_expressions_are_code(self):
        self.assertBlanked("`a;${db.c[k]}b`", "`__${db.c[k]}_`")

    def test_nested_templates_strings_and_braces_inside_expressions(self):
        self.assertBlanked("`x ${ `y ${a[k]}` } ${ {b: 'c'}.b } z`", "`__${ `__${a[k]}` }_${ {b: '_'}.b }__`")


class Refusals(unittest.TestCase):
    def test_unterminated_literals_and_comments(self):
        cases = {
            "f('open": "unterminated-string",
            "f('line\nbreak')": "unterminated-string",
            "f(/open": "unterminated-regex",
            "f(1 /* open": "unterminated-comment",
            "`open": "unterminated-template",
            "`${ open": "unterminated-template",
        }
        for code, reason in cases.items():
            with self.assertRaises(Unterminated) as caught:
                blank(code)
            self.assertEqual(str(caught.exception), reason, code)


class Cli(unittest.TestCase):
    def test_prints_the_blanked_code_or_the_reason(self):
        done = subprocess.run([sys.executable, "-I", str(LIB / "jsblank.py")], input="f('a;b')",
                              capture_output=True, text=True)
        self.assertEqual((done.returncode, done.stdout), (0, "f('   ')"))
        done = subprocess.run([sys.executable, "-I", str(LIB / "jsblank.py")], input="f('a",
                              capture_output=True, text=True)
        self.assertEqual((done.returncode, done.stdout), (1, "unterminated-string\n"))


if __name__ == "__main__":
    unittest.main()
