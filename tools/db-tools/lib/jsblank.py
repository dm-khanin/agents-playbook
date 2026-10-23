#!/usr/bin/env python3
"""Print a JavaScript expression with the inside of every literal and comment blanked out.

Reads stdin, writes stdout. Strings, template-literal text, regular-expression literals and comments keep
their delimiters, and their contents become spaces; code, including the ${...} parts of a template, stays.
mongo_reject_reason in safety.sh runs its structural checks (calls, computed members, a second statement)
on this view, so a ; or a [ inside a string or a regex is not taken for code. Exits 1 on an unterminated
literal or comment.

A / starts a regular expression only after a token that cannot end an operand (an operator, an opening
bracket, a comma, a keyword such as return or typeof, or the start of the text); everywhere else it is
division. When this guess is wrong, a regex is checked as code, which can only make the checks stricter.
"""
import sys

# Not } or ): in an expression an object literal or a call ends there, and a / after it divides.
REGEX_AFTER_CHARS = set("(,=:[!&|?{;+-*%<>~^")
REGEX_AFTER_WORDS = {"return", "typeof", "case", "in", "of", "new", "delete", "void", "instanceof", "do", "else"}


class Unterminated(Exception):
    pass


def blank(text: str) -> str:
    out = []
    i = _code(text, 0, out, in_template=False)
    if i != len(text):
        raise Unterminated("unbalanced-template")
    return "".join(out)


def _code(text, i, out, in_template):
    """Copy code from i; inside a template's ${...}, stop at its closing brace and return its index."""
    n = len(text)
    depth = 0
    previous = ""  # the last significant token: a character or a word
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j == -1:
                raise Unterminated("unterminated-comment")
            out.append(" " * (j + 2 - i))
            i = j + 2
        elif c in "'\"":
            i = _quoted(text, i, out, c)
            previous = "literal"
        elif c == "`":
            i = _template(text, i, out)
            previous = "literal"
        elif c == "/" and (previous == "" or previous in REGEX_AFTER_CHARS or previous in REGEX_AFTER_WORDS):
            i = _regex(text, i, out)
            previous = "literal"
        elif c.isalnum() or c in "_$":
            j = i
            while j < n and (text[j].isalnum() or text[j] in "_$"):
                j += 1
            previous = text[i:j]
            out.append(previous)
            i = j
        else:
            if in_template and c == "{":
                depth += 1
            elif in_template and c == "}":
                if depth == 0:
                    return i
                depth -= 1
            if not c.isspace():
                previous = c
            out.append(c)
            i += 1
    if in_template:
        raise Unterminated("unterminated-template")
    return i


def _quoted(text, i, out, quote):
    j = i + 1
    while j < len(text):
        if text[j] == "\\":
            j += 2
        elif text[j] == quote:
            out.append(quote + " " * (j - i - 1) + quote)
            return j + 1
        elif text[j] == "\n":
            break
        else:
            j += 1
    raise Unterminated("unterminated-string")


def _template(text, i, out):
    out.append("`")
    j = i + 1
    while j < len(text):
        if text[j] == "\\":
            out.append("  ")
            j += 2
        elif text[j] == "`":
            out.append("`")
            return j + 1
        elif text.startswith("${", j):
            out.append("${")
            j = _code(text, j + 2, out, in_template=True)
            out.append("}")
            j += 1
        else:
            out.append("\n" if text[j] == "\n" else " ")
            j += 1
    raise Unterminated("unterminated-template")


def _regex(text, i, out):
    j = i + 1
    in_class = False
    while j < len(text):
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == "\n":
            break
        if c == "[":
            in_class = True
        elif c == "]":
            in_class = False
        elif c == "/" and not in_class:
            j += 1
            while j < len(text) and text[j].isalpha():
                j += 1
            out.append("/" + " " * (j - i - 1))
            return j
        j += 1
    raise Unterminated("unterminated-regex")


if __name__ == "__main__":
    try:
        sys.stdout.write(blank(sys.stdin.read()))
    except Unterminated as error:
        print(error)
        sys.exit(1)
