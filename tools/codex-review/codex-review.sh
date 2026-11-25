#!/usr/bin/env bash
# codex-review.sh — an independent review of a branch by OpenAI Codex, read-only, written to a markdown file: a
# reviewer from another model family next to the ones the agent already runs.
#
# Usage: codex-review.sh <worktree> [--base <ref>] [--since <sha>] [--context <file>] [--effort <level>]
#                        [--model <slug>] [--out <file>] [--timeout <minutes>]
#   --base     the branch the PR targets; default the remote's HEAD (master or main). It is fetched first.
#   --since    a fix round: review only <sha>..HEAD, with the rest of the branch as context.
#   --context  a file appended to the prompt as background: decided rulings, accepted limits, a spec excerpt.
#              The open PR's title and body are added on their own when `gh` finds a PR for the branch.
#   --effort   low | medium | high | xhigh | max (default high).   --model   default gpt-6.2-sol.
#   --out      default ~/.claude/codex-reviews/<repo>-<branch>-<sha7>[-since-<sha7>].md
#   --timeout  minutes before Codex is killed (default 40).
#
# Codex reads the files on disk, so a worktree with modified tracked files is refused: the review would not
# match HEAD. Untracked files are fine. `codex exec review --base` takes no custom prompt (the CLI rejects the
# pair), so the range and the house rules go in as custom review instructions instead; review mode keeps its own
# reviewer prompt and output format either way. The user config is ignored so Codex starts without the desktop
# app's MCP servers and notify hook; auth still comes from ~/.codex.
#
# Environment:
#   CODEX_BIN                    the codex binary; default `codex` on PATH, then the one inside the macOS ChatGPT app.
#   CODEX_REVIEW_MODEL           the default for --model.
#   CODEX_REVIEW_CONVENTIONS     a markdown file whose `## Code` and `## Testing` sections are inlined into the prompt;
#                                default ~/.claude/CLAUDE.md. Missing file or sections: nothing is inlined.
#   CODEX_REVIEW_WORKSPACE_DOCS  space-separated paths, relative to a workspace root that holds several repositories,
#                                to maps of who consumes what across them. The root is the nearest of the three
#                                directories above the main checkout that contains the first path. Unset: no maps.
#
# Exit 0: review written, its path on the last line. 1: Codex failed, timed out or wrote nothing. 2: usage.
set -uo pipefail

usage() {
  echo "usage: $(basename "$0") <worktree> [--base <ref>] [--since <sha>] [--context <file>] [--effort <level>] [--model <slug>] [--out <file>] [--timeout <minutes>]" >&2
  exit 2
}
fail() {
  echo "codex-review: $1" >&2
  exit "${2:-1}"
}

[ $# -ge 1 ] || usage
worktree="$1"
shift
base='' since='' context='' effort='high' model="${CODEX_REVIEW_MODEL:-gpt-6.2-sol}" out='' timeout_min=40
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --base) base="$2" ;;
    --since) since="$2" ;;
    --context) context="$2" ;;
    --effort) effort="$2" ;;
    --model) model="$2" ;;
    --out) out="$2" ;;
    --timeout) timeout_min="$2" ;;
    *) usage ;;
  esac
  shift 2
done
case "$effort" in low | medium | high | xhigh | max) ;; *) fail "effort must be low|medium|high|xhigh|max, got: $effort" 2 ;; esac
# Whole minutes; a trailing "s" means seconds, which only the tests need.
case "$timeout_min" in
  '' | s | *[!0-9s]* | *s?*) fail "timeout must be whole minutes (or <n>s), got: $timeout_min" 2 ;;
  *s) timeout_secs="$((10#${timeout_min%s}))" ;;
  *) timeout_secs="$((10#$timeout_min * 60))" ;;
esac
[ "$timeout_secs" -gt 0 ] || fail "timeout must be positive, got: $timeout_min" 2
[ -z "$context" ] || [ -s "$context" ] || fail "context file is missing or empty: $context" 2

codex="${CODEX_BIN:-}"
if [ -z "$codex" ]; then
  codex="$(command -v codex || true)"
  [ -n "$codex" ] || codex='/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
fi
[ -x "$codex" ] || fail "no codex binary at $codex (set CODEX_BIN)" 2

cd "$worktree" 2>/dev/null || fail "no such directory: $worktree" 2
git rev-parse --git-dir >/dev/null 2>&1 || fail "not a git worktree: $worktree" 2
worktree="$(pwd -P)"
dirty="$(git status --porcelain --untracked-files=no)"
[ -z "$dirty" ] || fail "modified tracked files; commit or set them aside first, Codex reads the disk:
$dirty" 2

if [ -z "$base" ]; then
  base="$(git symbolic-ref -q --short refs/remotes/origin/HEAD || true)"
  if [ -z "$base" ]; then
    for candidate in origin/master origin/main; do
      git rev-parse -q --verify "$candidate" >/dev/null && { base="$candidate"; break; }
    done
  fi
  [ -n "$base" ] || fail "cannot tell the base branch; pass --base" 2
fi
case "$base" in
  origin/*) git fetch -q origin "${base#origin/}" 2>/dev/null || echo "codex-review: fetch of $base failed, using the local ref" >&2 ;;
esac
git rev-parse -q --verify "$base^{commit}" >/dev/null || fail "unknown base: $base" 2
head="$(git rev-parse HEAD)"
merge_base="$(git merge-base HEAD "$base")" || fail "no merge base between HEAD and $base" 2
[ "$merge_base" != "$head" ] || fail "HEAD has no commits beyond $base; nothing to review" 2
if [ -n "$since" ]; then
  since="$(git rev-parse -q --verify "$since^{commit}")" || fail "unknown --since commit" 2
  git merge-base --is-ancestor "$since" HEAD || fail "--since is not an ancestor of HEAD" 2
  [ "$since" != "$head" ] || fail "--since is HEAD; nothing to review" 2
fi

common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
main_root="$(dirname "$common_dir")"
repo="$(basename "$main_root")"
branch="$(git symbolic-ref -q --short HEAD || echo detached)"

rules=()
for f in "$worktree/CLAUDE.md" "$worktree/AGENTS.md" "$main_root/CLAUDE.local.md"; do
  [ -f "$f" ] && rules+=("$f")
done

# A diff-only review cannot see a consumer in a sibling repository; the workspace maps point it there.
workspace_docs="${CODEX_REVIEW_WORKSPACE_DOCS-}"
workspace=''
maps=()
if [ -n "$workspace_docs" ]; then
  read -r -a docs <<< "$workspace_docs"
  dir="$main_root"
  for _ in 1 2 3; do
    dir="$(dirname "$dir")"
    [ -e "$dir/${docs[0]}" ] && { workspace="$dir"; break; }
  done
  if [ -n "$workspace" ]; then
    for d in "${docs[@]}"; do
      [ -e "$workspace/$d" ] && maps+=("$workspace/$d")
    done
  fi
fi

pr_note='none'
pr_context=''
if command -v gh >/dev/null 2>&1 && [ "$branch" != 'detached' ]; then
  if pr_context="$(gh pr view "$branch" --json number,title,body --jq '"PR #\(.number): \(.title)\n\n\(.body)"' 2>/dev/null)" &&
    [ -n "$pr_context" ]; then
    pr_note="$(printf '%s' "$pr_context" | head -1 | cut -d: -f1)"
  else
    pr_context=''
  fi
fi

if [ -z "$out" ]; then
  slug="$(printf '%s' "$branch" | tr '/' '-' | tr -c 'A-Za-z0-9._-' '-')"
  out="$HOME/.claude/codex-reviews/$repo-$slug-${head:0:7}${since:+-since-${since:0:7}}.md"
fi
mkdir -p "$(dirname "$out")" || fail "cannot create $(dirname "$out")" 2
out="$(cd "$(dirname "$out")" && pwd -P)/$(basename "$out")"
events="${out%.md}.jsonl"
errlog="${out%.md}.err"
prompt_file="${out%.md}.prompt.txt"
rm -f "$out"

{
  if [ -n "$since" ]; then
    echo "Review the fix commits on this branch: the diff from $since to HEAD ($head)."
    echo "Run \`git diff $since HEAD\` and \`git log --oneline $since..HEAD\`. The whole branch, \`git diff $merge_base HEAD\`,"
    echo "is context only: report a problem outside the fix range only when the fix range causes or exposes it."
  else
    echo "Review the code changes on this branch: the diff from the merge base $merge_base (with $base) to HEAD ($head)."
    echo "Run \`git diff $merge_base HEAD\` and \`git log --oneline $merge_base..HEAD\`."
  fi
  echo "Review only committed changes; ignore anything uncommitted."
  echo
  if [ ${#rules[@]} -gt 0 ]; then
    echo "House rules and domain knowledge for this repository, read them before reviewing:"
    printf -- '- %s\n' "${rules[@]}"
  fi
  echo "Also read any CLAUDE.md or AGENTS.md in the directories the diff touches, and follow the topic docs their"
  echo "indexes point to when the diff is in that topic."
  if [ ${#maps[@]} -gt 0 ]; then
    echo
    echo "This repository is one of several independent repositories under $workspace; the others use it only through"
    echo "published packages, events, queues and shared databases. When the diff changes an exported API, an event or"
    echo "queue payload, a database column, or an enum value, find its consumers and check they still work. These maps"
    echo "say who produces and consumes what, and what each domain decided; then grep the sibling repositories:"
    printf -- '- %s\n' "${maps[@]}"
  fi
  # Inlined rather than pointed at: the rest of that file is personal and has no business in the prompt.
  conventions="$(awk '/^## (Code|Testing)$/ { p = 1; print; next } /^## / { p = 0 } p' "${CODEX_REVIEW_CONVENTIONS:-$HOME/.claude/CLAUDE.md}" 2>/dev/null)"
  if [ -n "$conventions" ]; then
    echo
    echo "The author's code and testing conventions:"
    echo '<conventions>'
    printf '%s\n' "$conventions"
    echo '</conventions>'
  fi
  echo
  echo "Focus on correctness: logic bugs, broken invariants, missed edge cases, wrong SQL or query semantics,"
  echo "races, error handling that hides a failure, contract changes that break a caller or consumer, and tests"
  echo "that would still pass with a wrong implementation. Before calling a removed or narrowed branch dead, check"
  echo "its history with \`git log -S\`. Prove each finding with a concrete input and the wrong result it produces."
  echo "Do not report style nits, naming preferences, or speculative hardening that changes no behaviour for a"
  echo "real input. The sandbox is read-only: you cannot run tests or install anything, so read the code instead."
  if [ -n "$pr_context" ]; then
    echo
    echo "The pull request's own description, for intent (check that the code does what it claims):"
    echo '<pr-description>'
    printf '%s\n' "$pr_context"
    echo '</pr-description>'
  fi
  if [ -n "$context" ]; then
    echo
    echo "Background from the author: decided rulings and accepted limits are not findings."
    echo '<author-context>'
    cat "$context"
    echo '</author-context>'
  fi
} > "$prompt_file"

started="$(date +%s)"
range="vs $base"
[ -z "$since" ] || range="since ${since:0:9} (fix round)"
echo "codex-review: $repo $branch ${head:0:9} $range, $model/$effort, pr context: $pr_note, timeout ${timeout_secs}s" >&2
timeout -k 30 "$timeout_secs" "$codex" exec review \
  -m "$model" \
  -c "review_model=\"$model\"" \
  -c "model_reasoning_effort=\"$effort\"" \
  -c 'sandbox_mode="read-only"' \
  -c 'approval_policy="never"' \
  --ignore-user-config --ephemeral --json \
  -o "$out" - < "$prompt_file" > "$events" 2> "$errlog"
code=$?
secs=$(($(date +%s) - started))

if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
  fail "timed out after ${timeout_secs}s; partial events in $events"
fi
[ "$code" -eq 0 ] || fail "codex exited $code after ${secs}s; see $errlog
$(tail -5 "$errlog")"
[ -s "$out" ] || fail "codex exited 0 but wrote no review; see $events and $errlog"

usage_line="$(python3 -I - "$events" <<'PY' 2>/dev/null
import json, sys
total = {}
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("type") == "turn.completed":
        for key, value in (event.get("usage") or {}).items():
            if isinstance(value, int):
                total[key] = total.get(key, 0) + value
# With ChatGPT auth every counter arrives as 0; that is "not reported", not a free run.
print(", ".join(f"{k}={v}" for k, v in sorted(total.items())) if any(total.values()) else "usage not reported")
PY
)"
echo "codex-review: done in $((secs / 60))m$((secs % 60))s; ${usage_line:-no usage reported}" >&2
echo "$out"
