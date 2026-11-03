#!/bin/sh
# Run shellcheck over every tracked shell script, with the one shellcheck version CI uses.
# Versions disagree on what they report (one flags a pattern another accepts, or names the same check with a
# different code), so a different local version can pass here and fail in CI. This refuses to run on any other
# version. CI installs this version from the release archive, checked against SHELLCHECK_SHA256 in ci.yml.
set -eu
SHELLCHECK_VERSION=0.11.0
cd "$(git rev-parse --show-toplevel)"
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck.sh: shellcheck $SHELLCHECK_VERSION is not installed" >&2
  exit 1
fi
have=$(shellcheck --version | sed -n 's/^version: //p')
if [ "$have" != "$SHELLCHECK_VERSION" ]; then
  echo "shellcheck.sh: need shellcheck $SHELLCHECK_VERSION, found ${have:-unknown}" >&2
  exit 1
fi
git ls-files -z '*.sh' '.githooks/*' 'tools/leak-guard/githooks/*' | xargs -0 shellcheck
