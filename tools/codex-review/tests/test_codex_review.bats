#!/usr/bin/env bats
# codex-review.sh: the range Codex is told to review (merge base, not the base tip), the read-only flags, the
# house-rule files from the main checkout, refusals that must not call Codex, and every failure path exiting 1.
# bash 3.2: a [[ ]] or a negated `! grep` mid-test needs `|| false`, or bats never sees it fail.

SCRIPT="$BATS_TEST_DIRNAME/../codex-review.sh"

setup() {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  T="$BATS_TEST_TMPDIR"
  LOGDIR="$T/codex-log"
  mkdir -p "$LOGDIR" "$T/bin"
  export LOGDIR

  # origin with main at A; a clone whose feature branch forks at A; then origin/main moves on to C, so the merge
  # base (A) and the base tip (C) differ and a script that diffs against the tip is caught.
  git init -q --bare -b main "$T/origin.git"
  git init -q -b main "$T/seed"
  echo 'a' > "$T/seed/a.txt"
  echo '# rules' > "$T/seed/CLAUDE.md"
  git -C "$T/seed" add -A && git -C "$T/seed" commit -q -m A
  git -C "$T/seed" remote add origin "$T/origin.git" && git -C "$T/seed" push -q origin main
  SHA_A="$(git -C "$T/seed" rev-parse HEAD)"
  git clone -q "$T/origin.git" "$T/repo"
  echo 'local rules' > "$T/repo/CLAUDE.local.md"
  git -C "$T/repo" worktree add -q -b feat/add-thing "$T/wt" main
  WT="$T/wt"
  echo 'b' > "$WT/b.txt"
  git -C "$WT" add b.txt && git -C "$WT" commit -q -m B
  SHA_B="$(git -C "$WT" rev-parse HEAD)"
  echo 'b2' > "$WT/b.txt"
  git -C "$WT" commit -q -am B2
  SHA_B2="$(git -C "$WT" rev-parse HEAD)"
  echo 'c' > "$T/seed/c.txt"
  git -C "$T/seed" add -A && git -C "$T/seed" commit -q -m C && git -C "$T/seed" push -q origin main
  SHA_C="$(git -C "$T/seed" rev-parse HEAD)"

  # Fake codex: records argv one per line and the prompt from stdin, prints JSONL events with usage, writes the
  # -o file unless CODEX_NO_OUTPUT, sleeps CODEX_SLEEP, exits CODEX_EXIT.
  cat > "$T/bin/codex" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$LOGDIR/args.txt"
cat > "$LOGDIR/prompt.txt"
out=''
prev=''
for a in "$@"; do [ "$prev" = '-o' ] && out="$a"; prev="$a"; done
[ -n "$out" ] && : > "$out"
echo '{"type":"thread.started","thread_id":"x"}'
[ -n "${CODEX_SLEEP:-}" ] && sleep "$CODEX_SLEEP"
if [ -n "${CODEX_ZERO_USAGE:-}" ]; then
  echo '{"type":"turn.completed","usage":{"input_tokens":0,"output_tokens":0}}'
else
  echo '{"type":"turn.completed","usage":{"input_tokens":1200,"output_tokens":34}}'
fi
echo 'stderr noise' >&2
[ -z "${CODEX_NO_OUTPUT:-}" ] && [ -n "$out" ] && printf '%s\n' '[P1] Off-by-one in b.txt' > "$out"
exit "${CODEX_EXIT:-0}"
EOF
  chmod +x "$T/bin/codex"
  export CODEX_BIN="$T/bin/codex"
  # gh fails by default: no PR context, and no test ever reaches the real GitHub.
  printf '#!/bin/bash\n[ -n "${GH_OUT:-}" ] && { printf "%%s\\n" "$GH_OUT"; exit 0; }\nexit 1\n' > "$T/bin/gh"
  chmod +x "$T/bin/gh"
  export PATH="$T/bin:$PATH"
  mkdir -p "$T/out"
  printf '# Me\nprivate person line\n\n## Code\n\n- Never the non-null assertion.\n\n## Testing\n\n- A test must fail when the code is wrong.\n\n## Slack\n\nprivate slack line\n' > "$T/conventions.md"
  export CODEX_REVIEW_CONVENTIONS="$T/conventions.md"
  export CODEX_REVIEW_WORKSPACE_DOCS="maps/estate maps/domains"
  OUT="$T/out/review.md"
  # The script resolves symlinks (/var -> /private/var on macOS); compare against the resolved path.
  OUT_REAL="$(cd "$T/out" && pwd -P)/review.md"
}

arg_after() { awk -v k="$1" 'p { print; exit } $0 == k { p = 1 }' "$LOGDIR/args.txt"; }

@test "reviews merge-base..HEAD, not the moved base tip, and prints the review path last" {
  run "$SCRIPT" "$WT" --out "$OUT"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]} - 1]}" = "$OUT_REAL" ]
  grep -q "git diff $SHA_A HEAD" "$LOGDIR/prompt.txt"
  ! grep -q "$SHA_C" "$LOGDIR/prompt.txt" || false
  grep -q "($SHA_B2)" "$LOGDIR/prompt.txt"
  grep -qx '\[P1\] Off-by-one in b.txt' "$OUT"
  [[ "$output" == *"input_tokens=1200, output_tokens=34"* ]] || false
}

@test "runs Codex read-only, non-interactive, without the user config, model and effort on review_model too" {
  run "$SCRIPT" "$WT" --out "$OUT" --effort xhigh --model gpt-test
  [ "$status" -eq 0 ]
  [ "$(sed -n 1,2p "$LOGDIR/args.txt" | tr '\n' ' ')" = "exec review " ]
  [ "$(arg_after -m)" = "gpt-test" ]
  grep -qx 'review_model="gpt-test"' "$LOGDIR/args.txt"
  grep -qx 'model_reasoning_effort="xhigh"' "$LOGDIR/args.txt"
  grep -qx 'sandbox_mode="read-only"' "$LOGDIR/args.txt"
  grep -qx 'approval_policy="never"' "$LOGDIR/args.txt"
  grep -qx -- '--ignore-user-config' "$LOGDIR/args.txt"
  grep -qx -- '--ephemeral' "$LOGDIR/args.txt"
  [ "$(arg_after -o)" = "$OUT_REAL" ]
  # The CLI rejects --base together with a prompt; the range travels in the prompt instead.
  ! grep -qx -- '--base' "$LOGDIR/args.txt" || false
  [ "$(tail -1 "$LOGDIR/args.txt")" = "-" ]
}

@test "lists the worktree's CLAUDE.md and the main checkout's untracked CLAUDE.local.md as house rules" {
  run "$SCRIPT" "$WT" --out "$OUT"
  [ "$status" -eq 0 ]
  grep -qx -- "- $(cd "$WT" && pwd -P)/CLAUDE.md" "$LOGDIR/prompt.txt"
  grep -qx -- "- $(cd "$T/repo" && pwd -P)/CLAUDE.local.md" "$LOGDIR/prompt.txt"
  ! grep -q "AGENTS.md$" "$LOGDIR/prompt.txt" || false
}

@test "default output path names repo, branch and head sha" {
  export HOME="$T/fakehome"
  run "$SCRIPT" "$WT"
  [ "$status" -eq 0 ]
  expected="$T/fakehome/.claude/codex-reviews/repo-feat-add-thing-${SHA_B2:0:7}.md"
  [ "$(cd "$(dirname "${lines[${#lines[@]} - 1]}")" && pwd -P)" = "$(cd "$(dirname "$expected")" && pwd -P)" ]
  [ "$(basename "${lines[${#lines[@]} - 1]}")" = "$(basename "$expected")" ]
}

@test "--since reviews only the fix range and names it in the file" {
  export HOME="$T/fakehome"
  run "$SCRIPT" "$WT" --since "$SHA_B"
  [ "$status" -eq 0 ]
  grep -q "git diff $SHA_B HEAD" "$LOGDIR/prompt.txt"
  grep -q "context only" "$LOGDIR/prompt.txt"
  [[ "$output" == *"since ${SHA_B:0:9} (fix round),"* ]] || false
  [[ "$output" != *"$SHA_B"* ]] || false
  [[ "${lines[${#lines[@]} - 1]}" == *"-${SHA_B2:0:7}-since-${SHA_B:0:7}.md" ]] || false
}

@test "--since that is not an ancestor of HEAD is refused without calling Codex" {
  run "$SCRIPT" "$WT" --out "$OUT" --since "$SHA_C"
  [ "$status" -eq 2 ]
  [ ! -f "$LOGDIR/args.txt" ]
}

@test "a modified tracked file is refused without calling Codex; an untracked file is fine" {
  echo 'dirty' >> "$WT/a.txt"
  run "$SCRIPT" "$WT" --out "$OUT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"a.txt"* ]] || false
  [ ! -f "$LOGDIR/args.txt" ]
  git -C "$WT" checkout -q -- a.txt
  echo 'scratch' > "$WT/notes.tmp"
  run "$SCRIPT" "$WT" --out "$OUT"
  [ "$status" -eq 0 ]
}

@test "a branch with nothing beyond the base is refused" {
  git -C "$T/repo" worktree add -q -b empty "$T/wt-empty" origin/main
  run "$SCRIPT" "$T/wt-empty" --out "$OUT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"nothing to review"* ]] || false
  [ ! -f "$LOGDIR/args.txt" ]
}

@test "the PR description and the author context go into the prompt" {
  export GH_OUT='PR #7: fix: a thing
Body line that states the intent.'
  printf 'Ruling: retries stay at 3.\n' > "$T/ctx.md"
  run "$SCRIPT" "$WT" --out "$OUT" --context "$T/ctx.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pr context: PR #7"* ]] || false
  grep -qx 'Body line that states the intent.' "$LOGDIR/prompt.txt"
  grep -qx 'Ruling: retries stay at 3.' "$LOGDIR/prompt.txt"
}

@test "without a PR the review still runs and says so" {
  run "$SCRIPT" "$WT" --out "$OUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pr context: none"* ]] || false
  ! grep -q '<pr-description>' "$LOGDIR/prompt.txt" || false
}

@test "Codex failing exits 1 and points at its stderr" {
  export CODEX_EXIT=3
  run "$SCRIPT" "$WT" --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"codex exited 3"* ]] || false
  [[ "$output" == *"stderr noise"* ]] || false
}

@test "Codex exiting 0 with an empty review exits 1" {
  export CODEX_NO_OUTPUT=1
  run "$SCRIPT" "$WT" --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"wrote no review"* ]] || false
}

@test "a hung Codex is killed at the timeout and exits 1" {
  export CODEX_SLEEP=20
  start=$(date +%s)
  run "$SCRIPT" "$WT" --out "$OUT" --timeout 2s
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out after 2s"* ]] || false
  [ $(($(date +%s) - start)) -lt 15 ]
}

@test "bad arguments exit 2 without calling Codex" {
  run "$SCRIPT" "$WT" --effort huge
  [ "$status" -eq 2 ]
  run "$SCRIPT" "$WT" --timeout 5m
  [ "$status" -eq 2 ]
  run "$SCRIPT" "$WT" --context "$T/missing.md"
  [ "$status" -eq 2 ]
  run "$SCRIPT" "$T"
  [ "$status" -eq 2 ]
  run "$SCRIPT" "$WT" --base
  [ "$status" -eq 2 ]
  [ ! -f "$LOGDIR/args.txt" ]
}

@test "inlines only the Code and Testing sections of the conventions file" {
  run "$SCRIPT" "$WT" --out "$OUT"
  [ "$status" -eq 0 ]
  grep -qx -- '- Never the non-null assertion.' "$LOGDIR/prompt.txt"
  grep -qx -- '- A test must fail when the code is wrong.' "$LOGDIR/prompt.txt"
  ! grep -q 'private person line' "$LOGDIR/prompt.txt" || false
  ! grep -q 'private slack line' "$LOGDIR/prompt.txt" || false
  ! grep -q 'conventions.md' "$LOGDIR/prompt.txt" || false
}

@test "all-zero usage is reported as not reported, not as zero" {
  export CODEX_ZERO_USAGE=1
  run "$SCRIPT" "$WT" --out "$OUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage not reported"* ]] || false
  [[ "$output" != *"input_tokens=0"* ]] || false
}

@test "lists the workspace maps that exist, found from the first one, for cross-repo consumers" {
  run "$SCRIPT" "$WT" --out "$OUT"
  [ "$status" -eq 0 ]
  ! grep -q 'maps/' "$LOGDIR/prompt.txt" || false
  mkdir -p "$T/maps/estate"
  run "$SCRIPT" "$WT" --out "$OUT"
  [ "$status" -eq 0 ]
  root="$(cd "$T" && pwd -P)"
  grep -qx -- "- $root/maps/estate" "$LOGDIR/prompt.txt"
  ! grep -q 'maps/domains' "$LOGDIR/prompt.txt" || false
  mkdir -p "$T/maps/domains"
  run "$SCRIPT" "$WT" --out "$OUT"
  grep -qx -- "- $root/maps/domains" "$LOGDIR/prompt.txt"
}

@test "an empty CODEX_REVIEW_WORKSPACE_DOCS turns the maps off" {
  mkdir -p "$T/maps/estate"
  export CODEX_REVIEW_WORKSPACE_DOCS=''
  run "$SCRIPT" "$WT" --out "$OUT"
  [ "$status" -eq 0 ]
  ! grep -q 'maps/' "$LOGDIR/prompt.txt" || false
  ! grep -q 'independent repositories' "$LOGDIR/prompt.txt" || false
}
