#!/usr/bin/env python3
"""Read stdin, mask personal data and secrets, write stdout.

Always, also with --secrets-only:
  1. A password in a URL (scheme://user:password@host) becomes ***. Clients sometimes echo a connection
     string in an error message, and unmasked output must not carry it either.

Unless --secrets-only:
  2. E-mail: the first two characters of the local part stay, the rest becomes **, the domain stays.
     A backslash ends the local part, so an e-mail right after a JSON escape such as \\n keeps the escape
     intact and the line stays valid JSON; so do : / and *, so a URL keeps its scheme and a redacted
     password.
  3. Phone number in E.164 form: + and the first two digits stay, then stars, then the last two digits.
  4. Hex token of 32 or more characters: the first and last four stay. The threshold skips 24-character
     MongoDB ObjectIds, which are not personal data; a hex digest such as md5() output is masked too.
"""
import re
import sys

URL_PASSWORD_RE = re.compile(r"\b([a-z][a-z0-9+.-]*://[^\s:/?#@]+):[^\s@/]+@", re.IGNORECASE)

NON_EMAIL_CHAR = r"[^\s@\"',;<>(){}\[\]\\:/*]"

# The lookbehind lets a match start only where a run of NON_EMAIL_CHAR starts. Every e-mail the pattern can
# match starts there anyway (the greedy local part reaches back to the start of the run), so the output is
# the same; without it the engine retried the greedy local part from every position of a long run, which is
# quadratic: a 40K-character run took 14 s.
EMAIL_RE = re.compile(
    rf"(?<!{NON_EMAIL_CHAR})"
    rf"({NON_EMAIL_CHAR})"
    rf"({NON_EMAIL_CHAR}?)"
    rf"{NON_EMAIL_CHAR}*"
    rf"@({NON_EMAIL_CHAR}+\.{NON_EMAIL_CHAR}{{2,}})",
    re.UNICODE,
)
PHONE_RE = re.compile(r"(\+[0-9]{2})[0-9]{3,}([0-9]{2})")
HEX_TOKEN_RE = re.compile(r"([A-Fa-f0-9]{4})[A-Fa-f0-9]{24,}([A-Fa-f0-9]{4})")


def redact_secrets(text: str) -> str:
    return URL_PASSWORD_RE.sub(r"\1:***@", text)


def mask(text: str) -> str:
    text = redact_secrets(text)
    text = EMAIL_RE.sub(r"\1\2**@\3", text)
    text = PHONE_RE.sub(r"\1*******\2", text)
    text = HEX_TOKEN_RE.sub(r"\1****\2", text)
    return text


if __name__ == "__main__":
    data = sys.stdin.read()
    sys.stdout.write(redact_secrets(data) if sys.argv[1:] == ["--secrets-only"] else mask(data))
