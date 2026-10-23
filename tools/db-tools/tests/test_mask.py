"""Tests for lib/mask.py: personal data masked, URL passwords redacted, linear time on long input."""

import json
import random
import re
import subprocess
import sys
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB))

from mask import EMAIL_RE, mask, redact_secrets  # noqa: E402


class Email(unittest.TestCase):
    def test_first_two_characters_of_the_local_part_stay(self):
        self.assertEqual(mask("contact: alice@example.com"), "contact: al**@example.com")

    def test_dots_and_plus_addressing(self):
        self.assertEqual(mask("a.b+tag@example.org"), "a.**@example.org")

    def test_short_local_parts(self):
        self.assertEqual(mask("ab@example.org"), "ab**@example.org")
        self.assertEqual(mask("a@example.org"), "a**@example.org")

    def test_unicode_local_part_and_domain(self):
        self.assertEqual(mask("user иван@example.ru"), "user ив**@example.ru")
        self.assertEqual(mask("user alice@пример.рф"), "user al**@пример.рф")

    def test_an_email_after_a_json_escape_leaves_valid_json(self):
        for escape in ("\n", "\t", "\\", '"'):
            line = json.dumps({"note": f"x{escape}alice@example.com"})
            masked = mask(line)
            self.assertNotIn("alice", masked)
            self.assertEqual(json.loads(masked)["note"][-14:], "al**@example.com"[-14:], masked)


class OtherPersonalData(unittest.TestCase):
    def test_phone_numbers_in_e164_form(self):
        self.assertEqual(mask("call +14155551234 now"), "call +14*******34 now")

    def test_digits_without_a_plus_are_not_a_phone(self):
        self.assertEqual(mask("id=14155551234"), "id=14155551234")

    def test_long_hex_tokens_keep_four_and_four(self):
        self.assertEqual(mask("token=abcdef0123456789abcdef0123456789abcdef"), "token=abcd****cdef")

    def test_short_hex_and_objectids_are_not_tokens(self):
        self.assertEqual(mask("color=abcdef"), "color=abcdef")
        self.assertEqual(mask('_id: "507f1f77bcf86cd799439011"'), '_id: "507f1f77bcf86cd799439011"')

    def test_names_are_not_masked(self):
        self.assertEqual(mask("name: John Doe"), "name: John Doe")

    def test_several_kinds_on_one_line(self):
        self.assertEqual(mask("user alice@example.com phone +14155551234"),
                         "user al**@example.com phone +14*******34")


class Secrets(unittest.TestCase):
    def test_a_url_password_is_redacted(self):
        self.assertEqual(redact_secrets("could not connect to postgresql://app:s3cr3t@example.com/x"),
                         "could not connect to postgresql://app:***@example.com/x")
        self.assertEqual(redact_secrets("mongodb+srv://u:p%40ss@example.net/db?w=majority"),
                         "mongodb+srv://u:***@example.net/db?w=majority")

    def test_a_url_without_a_password_is_untouched(self):
        for text in ("https://example.com/a", "postgres://app@example.com/x", "redis://db.example.com:6379"):
            self.assertEqual(redact_secrets(text), text)

    def test_masking_redacts_too(self):
        self.assertEqual(mask("rediss://default:pw@example.com:6380"), "rediss://default:***@example.com:6380")


class Performance(unittest.TestCase):
    def test_linear_on_long_runs(self):
        # A psql dash rule as wide as a large cell, a long local part and a long domain. The pattern without
        # the lookbehind needs minutes to hours here; re.sub cannot be interrupted, so it runs in a child.
        text = "-" * 200_000 + "\n" + "x" * 200_000 + "@" + "y" * 200_000 + "\n"
        try:
            done = subprocess.run([sys.executable, "-I", str(LIB / "mask.py")], input=text, capture_output=True,
                                  text=True, timeout=5)
        except subprocess.TimeoutExpired:
            self.fail("masking took longer than 5 s")
        self.assertEqual(done.stdout, text, "nothing in this input is personal data")

    def test_the_lookbehind_changes_no_output(self):
        excluded = r"[^\s@\"',;<>(){}\[\]\\:/*]"
        oracle = re.compile(rf"({excluded})({excluded}?){excluded}*@({excluded}+\.{excluded}{{2,}})", re.UNICODE)
        alphabet = list("ab.-@ ,+1:/*\"(иx\\") + ["\n", "\t"]
        rng = random.Random(20261014)
        for _ in range(20_000):
            text = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 40)))
            self.assertEqual(EMAIL_RE.sub(r"\1\2**@\3", text), oracle.sub(r"\1\2**@\3", text), text)


class Cli(unittest.TestCase):
    def run_cli(self, *args, text):
        return subprocess.run([sys.executable, "-I", str(LIB / "mask.py"), *args], input=text,
                              capture_output=True, text=True).stdout

    def test_default_masks_everything(self):
        self.assertEqual(self.run_cli(text="alice@example.com postgres://u:pw@h/db"),
                         "al**@example.com postgres://u:***@h/db")

    def test_secrets_only_keeps_personal_data(self):
        self.assertEqual(self.run_cli("--secrets-only", text="alice@example.com postgres://u:pw@h/db"),
                         "alice@example.com postgres://u:***@h/db")


if __name__ == "__main__":
    unittest.main()
