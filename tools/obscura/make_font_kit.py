#!/usr/bin/env python3
"""Copy a curated set of macOS system fonts into a directory for `obscura --font-dir`.

Obscura scans no system fonts, so CJK, Thai and Devanagari render as boxes without
this. Files are copied, not linked: Obscura's font loader skips symlinks on purpose.
Loading the whole system font directory instead costs hundreds of megabytes and
lets fallback pick fonts that break Arabic shaping.
"""
from __future__ import annotations

import argparse
import os
import shutil
import sys
import unicodedata
from pathlib import Path

FONTS = [
    "Hiragino Sans GB.ttc",        # Simplified Chinese, kana
    "ヒラギノ角ゴシック W3.ttc",    # Japanese regular
    "ヒラギノ角ゴシック W6.ttc",    # Japanese bold
    "AppleSDGothicNeo.ttc",         # Korean
    "ThonburiUI.ttc",               # Thai
    "ArialHB.ttc",                  # Hebrew
    "Kohinoor.ttc",                 # Devanagari
]


def default_dest() -> Path:
    base = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(base) / "obscura" / "fonts"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("dest", nargs="?", type=Path, default=default_dest())
    parser.add_argument("--source", type=Path, default=Path("/System/Library/Fonts"))
    args = parser.parse_args(argv)
    available = {unicodedata.normalize("NFC", p.name): p for p in args.source.iterdir()}
    args.dest.mkdir(parents=True, exist_ok=True)
    missing = []
    for name in FONTS:
        source = available.get(unicodedata.normalize("NFC", name))
        if source is None:
            missing.append(name)
            continue
        target = args.dest / name
        if target.is_file() and not target.is_symlink() and target.stat().st_size == source.stat().st_size:
            print(f"already present: {name}")
            continue
        if target.is_symlink():
            target.unlink()
        shutil.copyfile(source, target)
        print(f"copied: {name}")
    for name in missing:
        print(f"missing in {args.source}: {name}", file=sys.stderr)
    print(f"font kit: {args.dest}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
