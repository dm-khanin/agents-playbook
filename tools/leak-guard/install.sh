#!/bin/sh
# Install leak-guard into a git repository: the scanner and three hooks under .leak-guard/, an empty allowlist if
# there is none, and an ignore rule for the private pattern file. Git configuration is left to the owner.
# Usage: install.sh <path-to-git-repository>
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: install.sh <path-to-git-repository>" >&2
  exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
if ! top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null); then
  echo "leak-guard: not a git work tree: $1" >&2
  exit 2
fi

mkdir -p "$top/.leak-guard/hooks"
cp "$here/leak_scan.py" "$top/.leak-guard/leak_scan.py"
for hook in pre-commit commit-msg pre-push; do
  cp "$here/githooks/$hook" "$top/.leak-guard/hooks/$hook"
  chmod 755 "$top/.leak-guard/hooks/$hook"
done

if [ ! -e "$top/.leakguard-allow" ]; then
  printf '%s\n' '# Exact "<path> <public-pattern-id>" pairs that are intentionally present, one per line.' \
    > "$top/.leakguard-allow"
fi

ignore="$top/.gitignore"
touch "$ignore"
if ! git -C "$top" check-ignore -q .leakguard.local; then
  if [ -s "$ignore" ] && [ -n "$(tail -c 1 "$ignore")" ]; then
    printf '\n' >> "$ignore"
  fi
  printf '%s\n' '.leakguard.local' >> "$ignore"
fi

if git -C "$top" ls-files --error-unmatch .leakguard.local >/dev/null 2>&1; then
  echo "leak-guard: WARNING: .leakguard.local is tracked by git; remove it from the index and the history before publishing" >&2
fi

cat <<EOF
leak-guard installed in $top/.leak-guard
Next:
  git -C "$top" config core.hooksPath .leak-guard/hooks
  put private patterns, one regular expression per line, in $top/.leakguard.local
  CI: copy $here/ci/leak-scan.yml into .github/workflows/ and add the LEAKGUARD_PATTERNS secret
EOF
