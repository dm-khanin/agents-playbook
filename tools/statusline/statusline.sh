#!/usr/bin/env bash
# Claude Code statusline. Reads JSON payload on stdin, prints a one-line status.
# Fields: cwd, model, git branch+dirty, context tokens, session duration.
set -u

input=$(cat)

model_name=$(jq -r '.model.display_name // .model.id // "?"' <<<"$input")
cwd=$(jq -r '.workspace.current_dir // .cwd // ""' <<<"$input")
duration_ms=$(jq -r '.cost.total_duration_ms // 0' <<<"$input")

short_cwd="${cwd/#$HOME/~}"

branch_seg=""
if br=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null); then :
elif br=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null); then :
else br=""; fi
if [ -n "$br" ]; then
  dirty=""
  if [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null | head -c1)" ]; then dirty="*"; fi
  branch_seg="  🌿 ${br}${dirty}"
fi

ctx_seg=""
ctx_fields=$(jq -r '
  [
    (.context_window.context_window_size // empty),
    (.context_window.used_percentage // empty),
    ((.context_window.current_usage.input_tokens // 0)
     + (.context_window.current_usage.cache_read_input_tokens // 0)
     + (.context_window.current_usage.cache_creation_input_tokens // 0))
  ] | @tsv' <<<"$input" 2>/dev/null)
IFS=$'\t' read -r limit pct tokens <<<"$ctx_fields"
if [[ "$limit" =~ ^[0-9]+$ ]] && [[ "$pct" =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ]; then
  if [ "$tokens" -ge 1000 ]; then
    tok_h="$((tokens / 1000))k"
  else
    tok_h="$tokens"
  fi
  lim_h="$((limit / 1000))k"
  bar_w=10
  full=$(( pct * bar_w / 100 ))
  [ "$full" -gt "$bar_w" ] && full="$bar_w"
  [ "$full" -lt 0 ] && full=0
  empty=$(( bar_w - full ))
  bar=""
  for ((i=0; i<full; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done
  if [ "$pct" -ge 80 ]; then
    color=$'\033[31m'
  elif [ "$pct" -ge 50 ]; then
    color=$'\033[33m'
  else
    color=$'\033[32m'
  fi
  reset=$'\033[0m'
  ctx_seg="  🧠 ${tok_h}/${lim_h} ${color}${bar}${reset} ${pct}%"
fi

total_sec=$((duration_ms / 1000))
h=$((total_sec / 3600))
m=$(( (total_sec / 60) % 60 ))
s=$((total_sec % 60))
if [ "$h" -gt 0 ]; then
  dur_seg=$(printf "  ⏱ %d:%02d:%02d" "$h" "$m" "$s")
else
  dur_seg=$(printf "  ⏱ %d:%02d" "$m" "$s")
fi

rate_seg=""
rate_fields=$(jq -r '
  [
    (.rate_limits.five_hour.used_percentage // empty),
    (.rate_limits.five_hour.resets_at // empty)
  ] | @tsv' <<<"$input" 2>/dev/null)
IFS=$'\t' read -r rate_pct resets_at <<<"$rate_fields"
if [[ "$rate_pct" =~ ^[0-9]+$ ]]; then
  bar_w=8
  full=$(( rate_pct * bar_w / 100 ))
  [ "$full" -gt "$bar_w" ] && full="$bar_w"
  [ "$full" -lt 0 ] && full=0
  empty=$(( bar_w - full ))
  bar=""
  for ((i=0; i<full; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done
  if [ "$rate_pct" -ge 80 ]; then
    color=$'\033[31m'
  elif [ "$rate_pct" -ge 50 ]; then
    color=$'\033[33m'
  else
    color=$'\033[32m'
  fi
  reset=$'\033[0m'
  # Time until reset
  reset_in=""
  if [[ "$resets_at" =~ ^[0-9]+$ ]]; then
    now=$(date +%s)
    diff=$(( resets_at - now ))
    if [ "$diff" -gt 0 ]; then
      rm=$(( diff / 60 ))
      rh=$(( rm / 60 ))
      rm=$(( rm % 60 ))
      if [ "$rh" -gt 0 ]; then
        reset_in=" ~${rh}h${rm}m"
      else
        reset_in=" ~${rm}m"
      fi
    fi
  fi
  rate_seg="  🚦 ${color}${bar}${reset} ${rate_pct}%${reset_in}"
fi

cost_seg=""
cost=$(jq -r '.cost.total_cost_usd // empty' <<<"$input" 2>/dev/null)
if [[ "$cost" =~ ^[0-9] ]]; then
  cost_fmt=$(printf "%.2f" "$cost")
  cost_seg="  💰 \$${cost_fmt}"
fi

printf "📁 %s  🤖 %s%s%s%s%s%s" "$short_cwd" "$model_name" "$branch_seg" "$ctx_seg" "$rate_seg" "$cost_seg" "$dur_seg"