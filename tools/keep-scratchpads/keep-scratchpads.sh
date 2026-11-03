#!/bin/bash
# keep-scratchpads.sh — keep Claude Code scratchpads alive past the macOS /tmp clean-up.
#
# macOS deletes files under /private/tmp whose access, modification and change times are all older than 3 days
# (com.apple.tmp_cleaner, daily at midnight).
# Claude Code keeps each session's scratchpad there, so a session resumed after a long weekend finds it gone.
# This refreshes the access times inside the scratchpads of sessions whose transcript changed in the last
# KEEP_DAYS days (default 30); older sessions are left for the clean-up.
#
# Overridable for tests: KEEP_SCRATCHPADS_ROOT, KEEP_SCRATCHPADS_PROJECTS, KEEP_DAYS.
ROOT="${KEEP_SCRATCHPADS_ROOT:-/private/tmp/claude-$(id -u)}"
PROJECTS="${KEEP_SCRATCHPADS_PROJECTS:-$HOME/.claude/projects}"
DAYS="${KEEP_DAYS:-30}"
case "$DAYS" in '' | *[!0-9]*) echo "KEEP_DAYS must be a number, got: $DAYS" >&2; exit 2 ;; esac
[ -d "$ROOT" ] || exit 0
for sdir in "$ROOT"/*/*/; do
  [ -d "$sdir" ] || continue
  session=$(basename "$sdir"); project=$(basename "$(dirname "$sdir")")
  t="$PROJECTS/$project/$session.jsonl"
  [ -f "$t" ] && [ -n "$(find "$t" -mtime -"$DAYS")" ] || continue
  find "$sdir" -exec touch -a {} + 2>/dev/null
done
exit 0
