#!/usr/bin/env python3
"""Decide whether a SQL text is exactly one read statement, splitting it the way PostgreSQL does.

Reads the text on stdin. When it passes, prints the mode on the first line and the statement on the rest,
and exits 0:

    cursor   SELECT, WITH, VALUES or TABLE: pg-query.sh reads it through a cursor, which caps the rows
    direct   EXPLAIN or SHOW: run as it is

Otherwise prints the reason and exits 1.

The lexer follows PostgreSQL with standard_conforming_strings on, which pg-query.sh sets for its
transaction: '...' with '' as the only escape, E'...' with backslash escapes, $tag$...$tag$, "..."
identifiers, -- comments and nested /* */ comments. U&'...' and U&"..." are refused rather than decoded,
and so is anything left open at the end. A ; or a function name inside a string or a comment is just text.

This check is the client half. The server half is the read-only transaction that pg-query.sh opens and
always rolls back; this file only has to stop what that transaction cannot: a second statement, which could
end the transaction, and the functions in DENIED_FUNCTIONS.
"""
import re
import sys
from typing import Iterator, NamedTuple

READ_STATEMENTS = {
    "select": "cursor",
    "with": "cursor",
    "values": "cursor",
    "table": "cursor",
    "explain": "direct",
    "show": "direct",
}

# Functions whose effect survives a read-only transaction and its rollback: signals to other sessions,
# configuration reloads, WAL, backup and replication control, server-side file access, statistics resets,
# connections to other servers, and the functions that run a query passed as a string (which would hide any
# other name inside a concatenated literal). Matched against every identifier, quoted or not, whatever the
# schema prefix. A SQL-level write inside any function is already refused by the transaction.
DENIED_FUNCTIONS = re.compile(
    r"""
      pg_(terminate|cancel)_backend | pg_reload_conf | pg_rotate_logfile | pg_promote
    | pg_log_backend_memory_contexts | pg_switch_wal | pg_create_restore_point
    | pg_(start|stop)_backup | pg_backup_(start|stop) | pg_wal_replay_(pause|resume)
    | pg_(create|drop|copy)_\w*replication_slot | pg_replication_slot_advance
    | pg_logical_slot_(get|peek)_\w*changes | pg_logical_emit_message | pg_replication_origin_\w+
    | pg_import_system_collations
    | pg_read_(binary_)?file | pg_ls_\w*dir | pg_stat_file | pg_file_\w+ | lo_(import|export)
    | pg_stat_reset\w* | pg_stat_statements_reset
    | dblink\w*
    | query_to_xml\w* | cursor_to_xml\w* | ts_stat | ts_rewrite
    """,
    re.VERBOSE,
)

WHITESPACE = " \t\n\r\f\v"
IDENT_START = re.compile(r"[A-Za-z_\u0080-\U0010ffff]")
IDENT_CHAR = re.compile(r"[A-Za-z0-9_$\u0080-\U0010ffff]")
DOLLAR_TAG = re.compile(r"\$([A-Za-z_\u0080-\U0010ffff][A-Za-z0-9_\u0080-\U0010ffff]*)?\$")


class Refused(Exception):
    pass


class Token(NamedTuple):
    kind: str  # word, ident (a "quoted" identifier), string, semicolon, other
    text: str
    start: int


def _skip_string(sql: str, quote_at: int, backslash_escapes: bool) -> int:
    """Return the index just past the string literal whose opening quote is at quote_at."""
    i = quote_at + 1
    while i < len(sql):
        c = sql[i]
        if backslash_escapes and c == "\\":
            i += 2
        elif c == "'":
            if sql.startswith("''", i):
                i += 2
            else:
                return i + 1
        else:
            i += 1
    raise Refused("unterminated-string")


def _skip_block_comment(sql: str, start: int) -> int:
    depth, i = 0, start
    while i < len(sql):
        if sql.startswith("/*", i):
            depth, i = depth + 1, i + 2
        elif sql.startswith("*/", i):
            depth, i = depth - 1, i + 2
            if depth == 0:
                return i
        else:
            i += 1
    raise Refused("unterminated-comment")


def lex(sql: str) -> Iterator[Token]:
    """Yield the tokens that matter here. Whitespace and comments are dropped."""
    i, n = 0, len(sql)
    while i < n:
        c = sql[i]
        if c in WHITESPACE:
            i += 1
        elif sql.startswith("--", i):
            while i < n and sql[i] not in "\n\r":
                i += 1
        elif sql.startswith("/*", i):
            i = _skip_block_comment(sql, i)
        elif c == "'":
            end = _skip_string(sql, i, backslash_escapes=False)
            yield Token("string", sql[i:end], i)
            i = end
        elif c == '"':
            end = sql.find('"', i + 1)
            while end != -1 and sql.startswith('""', end):
                end = sql.find('"', end + 2)
            if end == -1:
                raise Refused("unterminated-identifier")
            yield Token("ident", sql[i + 1:end].replace('""', '"'), i)
            i = end + 1
        elif c == "$" and DOLLAR_TAG.match(sql, i):
            tag = DOLLAR_TAG.match(sql, i).group(0)
            end = sql.find(tag, i + len(tag))
            if end == -1:
                raise Refused("unterminated-dollar-quote")
            yield Token("string", sql[i:end + len(tag)], i)
            i = end + len(tag)
        elif IDENT_START.match(c):
            j = i + 1
            while j < n and IDENT_CHAR.match(sql[j]):
                j += 1
            word = sql[i:j].lower()
            if word in ("e", "b", "x", "n") and sql.startswith("'", j):
                end = _skip_string(sql, j, backslash_escapes=(word == "e"))
                yield Token("string", sql[i:end], i)
                i = end
                continue
            if word == "u" and (sql.startswith("&'", j) or sql.startswith('&"', j)):
                raise Refused("unicode-escape-refused")
            yield Token("word", sql[i:j], i)
            i = j
        elif c == ";":
            yield Token("semicolon", c, i)
            i += 1
        else:
            yield Token("other", c, i)
            i += 1


def check(sql: str) -> tuple[str, str]:
    """Return (mode, statement) for one read statement, or raise Refused."""
    tokens = list(lex(sql))
    statement = sql
    semicolons = [t for t in tokens if t.kind == "semicolon"]
    if semicolons:
        last = semicolons[-1]
        if len(semicolons) > 1 or tokens[-1] is not last:
            raise Refused("multi-statement")
        statement = sql[:last.start]
        tokens.pop()
    if not tokens:
        raise Refused("empty-statement")

    first = next((t for t in tokens if not (t.kind == "other" and t.text == "(")), None)
    mode = READ_STATEMENTS.get(first.text.lower()) if first is not None and first.kind == "word" else None
    if mode is None:
        raise Refused("not-a-read-statement")

    for token in tokens:
        if token.kind in ("word", "ident") and DENIED_FUNCTIONS.fullmatch(token.text.lower()):
            raise Refused(f"denied-function: {token.text.lower()}")
    return mode, statement.strip()


def main() -> int:
    try:
        mode, statement = check(sys.stdin.read())
    except Refused as refusal:
        print(refusal)
        return 1
    print(mode)
    print(statement)
    return 0


if __name__ == "__main__":
    sys.exit(main())
