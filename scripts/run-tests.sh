#!/bin/sh
# Run every test suite in the repository: Python unittest per tests/ directory,
# Node's built-in runner for *.test.mjs, bats for *.bats. Exits non-zero if any
# suite fails, and when bats suites exist but bats is not installed.
set -eu
cd "$(git rev-parse --show-toplevel)"
status=0
for dir in $(git ls-files '*/tests/test_*.py' | xargs -n1 dirname | sort -u); do
  python3 -m unittest discover -s "$dir" -t "$dir" || status=1
done
node_tests=$(git ls-files '*.test.mjs')
if [ -n "$node_tests" ]; then
  # shellcheck disable=SC2086 # word splitting is intended: one argument per file
  node --test $node_tests || status=1
fi
bats_tests=$(git ls-files '*.bats')
if [ -n "$bats_tests" ]; then
  if command -v bats >/dev/null 2>&1; then
    # shellcheck disable=SC2086 # word splitting is intended: one argument per file
    bats $bats_tests || status=1
  else
    echo "run-tests: bats is not installed; these suites need it:" >&2
    echo "$bats_tests" >&2
    status=1
  fi
fi
exit "$status"
