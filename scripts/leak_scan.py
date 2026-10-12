#!/usr/bin/env python3
"""Scan a git repository for content that must not be published.

Public patterns are built in. Private patterns come from LEAKGUARD_PATTERNS
(newline-separated regular expressions) and from a git-ignored .leakguard.local,
and are never echoed, because the CI log of a public repository is public too:
a private finding names only the pattern's position, a line that matches a
private pattern prints no excerpt for any finding on it, and a file path that
matches one is shown as a hash. --reveal lifts both for local investigation.

Exit codes: 0 clean, 1 findings, 2 the scan could not run.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator

PUBLIC_PATTERNS: dict[str, re.Pattern] = {
    "home-path": re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+|\b[A-Za-z]:\\Users\\[A-Za-z0-9._-]+"),
    "email": re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"),
    "private-ip": re.compile(
        r"\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})\b"
    ),
}
ALLOWED_EMAIL = re.compile(
    r"(?:@example\.(?:com|org|net)|@users\.noreply\.github\.com|^noreply@anthropic\.com)$", re.IGNORECASE
)
BINARY_SNIFF_BYTES = 8000
MESSAGE = "<message>"


class ScanError(Exception):
    """The scan could not run; reported with exit code 2."""


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    pattern_id: str
    excerpt: str | None
    commit: str | None = None
    private_line: bool = False
    private_path: bool = False

    def render(self, reveal: bool = False) -> str:
        path = self.path
        if self.private_path and not reveal:
            path = f"<private path {hashlib.sha256(self.path.encode()).hexdigest()[:8]}>"
        where = path if self.commit is None else f"{self.commit}:{path}"
        head = f"{where}:{self.line}: {self.pattern_id}"
        hide_excerpt = self.excerpt is None or (self.private_line and not reveal)
        return head if hide_excerpt else f'{head}: "{self.excerpt}"'


def run_git(repo: Path, *args: str) -> str:
    try:
        result = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True,
                                encoding="utf-8", errors="replace")
    except OSError as exc:
        raise ScanError(f"cannot run git: {exc}") from exc
    if result.returncode != 0:
        raise ScanError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def run_git_bytes(repo: Path, *args: str) -> bytes:
    result = subprocess.run(["git", *args], cwd=repo, capture_output=True)
    if result.returncode != 0:
        raise ScanError(f"git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def repo_root(start: Path) -> Path:
    if not start.is_dir():
        raise ScanError(f"not a directory: {start}")
    return Path(run_git(start, "rev-parse", "--show-toplevel").strip())


def load_private_patterns(repo: Path) -> list[re.Pattern]:
    lines = os.environ.get("LEAKGUARD_PATTERNS", "").splitlines()
    local = repo / ".leakguard.local"
    if local.is_file():
        lines += local.read_text(encoding="utf-8").splitlines()
    patterns = []
    for raw in lines:
        text = raw.strip()
        if not text or text.startswith("#"):
            continue
        try:
            patterns.append(re.compile(text, re.IGNORECASE))
        except re.error:
            raise ScanError(f"private pattern #{len(patterns) + 1} is not a valid regular expression") from None
    return patterns


def load_allowlist(repo: Path) -> set[tuple[str, str]]:
    path = repo / ".leakguard-allow"
    if not path.is_file():
        return set()
    allowed = set()
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        text = raw.strip()
        if not text or text.startswith("#"):
            continue
        parts = text.split()
        if len(parts) != 2:
            raise ScanError(f".leakguard-allow:{number}: expected '<path> <pattern-id>'")
        file_path, pattern_id = parts
        if any(ch in file_path for ch in "*?["):
            raise ScanError(f".leakguard-allow:{number}: wildcards are not allowed")
        if pattern_id not in PUBLIC_PATTERNS:
            raise ScanError(f".leakguard-allow:{number}: only public pattern ids can be allowed")
        allowed.add((file_path, pattern_id))
    return allowed


def is_private(text: str, private: list[re.Pattern]) -> bool:
    return any(pattern.search(text) for pattern in private)


def scan_line(path: str, number: int, text: str, private: list[re.Pattern],
              commit: str | None = None, private_path: bool = False) -> Iterator[Finding]:
    private_hits = [index for index, pattern in enumerate(private, start=1) if pattern.search(text)]
    flags = {"commit": commit, "private_line": bool(private_hits), "private_path": private_path}
    for pattern_id, pattern in PUBLIC_PATTERNS.items():
        for match in pattern.finditer(text):
            value = match.group(0)
            if pattern_id == "email" and ALLOWED_EMAIL.search(value):
                continue
            yield Finding(path, number, pattern_id, value, **flags)
    for index in private_hits:
        yield Finding(path, number, f"private#{index}", None, **flags)


def scan_file(path: str, data: bytes, private: list[re.Pattern]) -> Iterator[Finding]:
    """Line 0 is the file's own path: a name can leak as well as content. Binary content is skipped."""
    private_path = is_private(path, private)
    yield from scan_line(path, 0, path, private, private_path=private_path)
    if b"\x00" in data[:BINARY_SNIFF_BYTES]:
        return
    for number, line in enumerate(data.decode("utf-8", errors="replace").splitlines(), start=1):
        yield from scan_line(path, number, line, private, private_path=private_path)


def scan_tree(repo: Path, private: list[re.Pattern]) -> Iterator[Finding]:
    for name in filter(None, run_git(repo, "ls-files", "-z").split("\0")):
        file_path = repo / name
        if file_path.is_file():
            yield from scan_file(name, file_path.read_bytes(), private)


def scan_staged(repo: Path, private: list[re.Pattern]) -> Iterator[Finding]:
    names = run_git(repo, "diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR").split("\0")
    for name in filter(None, names):
        yield from scan_file(name, run_git_bytes(repo, "show", f":{name}"), private)


def scan_history(repo: Path, private: list[re.Pattern]) -> Iterator[Finding]:
    """Every commit message and diff line on every ref. Line numbers index the log output."""
    if run_git(repo, "rev-parse", "--is-shallow-repository").strip() == "true":
        raise ScanError("history scan needs a full clone (in CI: actions/checkout with fetch-depth: 0)")
    log = run_git(repo, "log", "--all", "-p", "--no-color", "--no-ext-diff", "--format=commit %H%n%B")
    commit, path, private_path = "?", MESSAGE, False
    for number, line in enumerate(log.splitlines(), start=1):
        if line.startswith("commit ") and len(line) == 47:
            commit, path, private_path = line[7:19], MESSAGE, False
            continue
        if line.startswith("+++ b/"):
            path = line[6:]
            private_path = is_private(path, private)
        yield from scan_line(path, number, line, private, commit, private_path)


def scan_message(message_file: Path, private: list[re.Pattern]) -> Iterator[Finding]:
    """A commit message as git will record it: comment lines are dropped, the rest is scanned."""
    try:
        text = message_file.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise ScanError(f"cannot read message file: {exc}") from exc
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.startswith("#"):
            yield from scan_line(MESSAGE, number, line, private)


def filter_allowed(findings: Iterable[Finding], allowed: set[tuple[str, str]]) -> list[Finding]:
    return [f for f in findings if (f.path, f.pattern_id) not in allowed]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--staged", action="store_true", help="scan files staged for commit")
    mode.add_argument("--tree", action="store_true", help="scan every tracked file")
    mode.add_argument("--history", action="store_true", help="scan all commits, messages included")
    mode.add_argument("--message", metavar="FILE", help="scan a commit message file (commit-msg hook)")
    parser.add_argument("--require-private", action="store_true", help="fail if no private patterns are set")
    parser.add_argument("--reveal", action="store_true",
                        help="print private paths and excerpts; for local use only, never in CI")
    parser.add_argument("--repo", default=".", help="repository to scan (default: current directory)")
    args = parser.parse_args(argv)
    try:
        repo = repo_root(Path(args.repo).resolve())
        private = load_private_patterns(repo)
        if args.require_private and not private:
            raise ScanError("no private patterns configured (set LEAKGUARD_PATTERNS or .leakguard.local)")
        allowed = load_allowlist(repo)
        if args.message:
            findings = filter_allowed(scan_message(Path(args.message), private), allowed)
        else:
            scanner = scan_staged if args.staged else scan_history if args.history else scan_tree
            findings = filter_allowed(scanner(repo, private), allowed)
    except ScanError as exc:
        print(f"leak-scan: {exc}", file=sys.stderr)
        return 2
    for finding in findings:
        print(finding.render(reveal=args.reveal))
    print(f"leak-scan: {len(findings)} finding(s), {len(private)} private pattern(s) loaded", file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
