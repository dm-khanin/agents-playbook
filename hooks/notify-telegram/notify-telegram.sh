#!/bin/bash
# Claude Code PermissionRequest hook: approve, always-allow or deny a tool call from Telegram.
#
# Sends the pending request to a Telegram chat with three buttons and waits for an answer.
# Prints the decision as hook JSON; with no answer before the timeout (or no credentials) it
# exits 1 without output and the harness shows its normal terminal prompt instead.
# If the request was answered in the terminal, the next invocation marks the old message as such.
#
# Credentials come from TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID, or from the env file below
# (keep it chmod 600). TELEGRAM_HOOK_TIMEOUT sets the wait in seconds.
ENV_FILE="${TELEGRAM_HOOK_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/agents-playbook/telegram.env}"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"
POLL_TIMEOUT="${TELEGRAM_HOOK_TIMEOUT:-120}"
PENDING_DIR="${TMPDIR:-/tmp}/claude-tg-pending"

if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
  exit 1
fi

API="https://api.telegram.org/bot${BOT_TOKEN}"
mkdir -p "$PENDING_DIR"

# --- Clean up stale messages from previous invocations (fallback) ---
for f in "$PENDING_DIR"/*.msg; do
  [ -f "$f" ] || continue
  OLD_MSG_ID=$(cat "$f")
  curl -s -X POST "${API}/editMessageText" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg chat_id "$CHAT_ID" --arg msg_id "$OLD_MSG_ID" \
      --arg text "🖥 <b>Answered in the terminal</b>" \
      '{chat_id: $chat_id, message_id: ($msg_id | tonumber), text: $text, parse_mode: "HTML"}'
    )" > /dev/null 2>&1
  rm -f "$f"
done

# --- Parse input ---
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
SESSION_SHORT="${SESSION_ID:0:8}"
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
CWD_SHORT="${CWD##*/}"
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
PERM_SUGGESTIONS=$(echo "$INPUT" | jq -c '.permission_suggestions // []' 2>/dev/null)

SESSION_TITLE=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  SESSION_TITLE=$(head -20 "$TRANSCRIPT" \
    | jq -r 'select(.type == "user") | .message.content | if type == "array" then map(select(.type == "text")) | .[0].text else . end // empty' 2>/dev/null \
    | head -1 \
    | cut -c1-60)
fi
if [ -z "$SESSION_TITLE" ]; then
  SESSION_TITLE="$SESSION_SHORT"
fi

case "$TOOL_NAME" in
  Bash)
    DETAILS=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null | head -c 300)
    ;;
  Edit|Write)
    DETAILS=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
    ;;
  *)
    DETAILS=$(echo "$INPUT" | jq -r '.tool_input | tostring' 2>/dev/null | head -c 300)
    ;;
esac

escape_html() {
  echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

SAFE_TOOL=$(escape_html "$TOOL_NAME")
SAFE_DETAILS=$(escape_html "$DETAILS")
SAFE_CWD=$(escape_html "$CWD_SHORT")
SAFE_TITLE=$(escape_html "$SESSION_TITLE")

# Build session info (actual newlines, not \n)
SESSION_LINE="💬 <b>${SAFE_TITLE}</b>"
if [ -n "$AGENT_TYPE" ]; then
  SAFE_AGENT=$(escape_html "$AGENT_TYPE")
  SESSION_LINE="${SESSION_LINE}
🤖 ${SAFE_AGENT} · 📂 <code>${SAFE_CWD}</code>"
else
  SESSION_LINE="${SESSION_LINE}
📂 <code>${SAFE_CWD}</code>"
fi

REQ_ID="perm_$(date +%s)_$$"

MSG="⏳ <b>Claude Code is waiting for permission</b>

${SESSION_LINE}

Tool: <code>${SAFE_TOOL}</code>
Details:
<code>${SAFE_DETAILS}</code>"

KEYBOARD=$(jq -n \
  --arg allow "${REQ_ID}:allow" \
  --arg always "${REQ_ID}:always" \
  --arg deny "${REQ_ID}:deny" '{
  inline_keyboard: [[
    {text: "✅ Allow", callback_data: $allow},
    {text: "🔓 Always Allow", callback_data: $always},
    {text: "❌ Deny", callback_data: $deny}
  ]]
}')

# --- Send message ---
RESPONSE=$(curl -s -X POST "${API}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg chat_id "$CHAT_ID" \
    --arg text "$MSG" \
    --argjson reply_markup "$KEYBOARD" \
    '{chat_id: $chat_id, text: $text, parse_mode: "HTML", reply_markup: $reply_markup}'
  )")

MSG_ID=$(echo "$RESPONSE" | jq -r '.result.message_id // empty')

if [ -z "$MSG_ID" ]; then
  exit 1
fi

# Track this message for cleanup
PENDING_FILE="${PENDING_DIR}/${REQ_ID}.msg"
echo "$MSG_ID" > "$PENDING_FILE"


# --- Poll for Telegram response ---
LATEST=$(curl -s -X POST "${API}/getUpdates" \
  -H "Content-Type: application/json" \
  -d '{"offset": -1, "limit": 1}')
OFFSET=$(echo "$LATEST" | jq -r '.result[-1].update_id // 0' 2>/dev/null)
OFFSET=$((OFFSET + 1))

START_TIME=$(date +%s)
DECISION=""

while true; do
  NOW=$(date +%s)
  REMAINING=$((POLL_TIMEOUT - (NOW - START_TIME)))
  if [ $REMAINING -le 0 ]; then
    break
  fi

  POLL_SEC=10
  if [ $REMAINING -lt $POLL_SEC ]; then
    POLL_SEC=$REMAINING
  fi

  UPDATES=$(curl -s --max-time $((POLL_SEC + 5)) -X POST "${API}/getUpdates" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg offset "$OFFSET" --arg timeout "$POLL_SEC" \
      '{offset: ($offset | tonumber), timeout: ($timeout | tonumber), allowed_updates: ["callback_query"]}'
    )")

  COUNT=$(echo "$UPDATES" | jq '.result | length' 2>/dev/null)

  for i in $(seq 0 $(( ${COUNT:-0} - 1 ))); do
    UPDATE=$(echo "$UPDATES" | jq ".result[$i]")
    UPDATE_ID=$(echo "$UPDATE" | jq -r '.update_id')
    CB_DATA=$(echo "$UPDATE" | jq -r '.callback_query.data // ""')
    CB_ID=$(echo "$UPDATE" | jq -r '.callback_query.id // ""')

    OFFSET=$((UPDATE_ID + 1))

    case "$CB_DATA" in
      "${REQ_ID}:allow")
        DECISION="allow"
        curl -s -X POST "${API}/answerCallbackQuery" -H "Content-Type: application/json" -d "{\"callback_query_id\":\"${CB_ID}\",\"text\":\"Allowed\"}" > /dev/null 2>&1
        curl -s -X POST "${API}/editMessageText" \
          -H "Content-Type: application/json" \
          -d "$(jq -n --arg chat_id "$CHAT_ID" --arg msg_id "$MSG_ID" \
            --arg text "$(printf "✅ <b>Allowed</b>\n\nTool: <code>%s</code>\nDetails:\n<code>%s</code>" "$SAFE_TOOL" "$SAFE_DETAILS")" \
            '{chat_id: $chat_id, message_id: ($msg_id | tonumber), text: $text, parse_mode: "HTML"}'
          )" > /dev/null 2>&1
        break 2
        ;;
      "${REQ_ID}:always")
        DECISION="always"
        curl -s -X POST "${API}/answerCallbackQuery" -H "Content-Type: application/json" -d "{\"callback_query_id\":\"${CB_ID}\",\"text\":\"Always Allowed\"}" > /dev/null 2>&1
        curl -s -X POST "${API}/editMessageText" \
          -H "Content-Type: application/json" \
          -d "$(jq -n --arg chat_id "$CHAT_ID" --arg msg_id "$MSG_ID" \
            --arg text "$(printf "🔓 <b>Always allowed</b>\n\nTool: <code>%s</code>\nDetails:\n<code>%s</code>" "$SAFE_TOOL" "$SAFE_DETAILS")" \
            '{chat_id: $chat_id, message_id: ($msg_id | tonumber), text: $text, parse_mode: "HTML"}'
          )" > /dev/null 2>&1
        break 2
        ;;
      "${REQ_ID}:deny")
        DECISION="deny"
        curl -s -X POST "${API}/answerCallbackQuery" -H "Content-Type: application/json" -d "{\"callback_query_id\":\"${CB_ID}\",\"text\":\"Denied\"}" > /dev/null 2>&1
        curl -s -X POST "${API}/editMessageText" \
          -H "Content-Type: application/json" \
          -d "$(jq -n --arg chat_id "$CHAT_ID" --arg msg_id "$MSG_ID" \
            --arg text "$(printf "❌ <b>Denied</b>\n\nTool: <code>%s</code>\nDetails:\n<code>%s</code>" "$SAFE_TOOL" "$SAFE_DETAILS")" \
            '{chat_id: $chat_id, message_id: ($msg_id | tonumber), text: $text, parse_mode: "HTML"}'
          )" > /dev/null 2>&1
        break 2
        ;;
    esac
  done
done

# Clean up pending file (we handled it ourselves)
rm -f "$PENDING_FILE"

if [ "$DECISION" = "allow" ]; then
  jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}}}'
  exit 0
elif [ "$DECISION" = "always" ]; then
  jq -n --argjson suggestions "$PERM_SUGGESTIONS" \
    '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow", updatedPermissions: $suggestions}}}'
  exit 0
elif [ "$DECISION" = "deny" ]; then
  jq -n '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny"}}}'
  exit 0
else
  curl -s -X POST "${API}/editMessageText" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg chat_id "$CHAT_ID" --arg msg_id "$MSG_ID" \
      --arg text "$(printf "⏰ <b>Timed out, waiting in the terminal</b>\n\nTool: <code>%s</code>" "$SAFE_TOOL")" \
      '{chat_id: $chat_id, message_id: ($msg_id | tonumber), text: $text, parse_mode: "HTML"}'
    )" > /dev/null 2>&1
  exit 1
fi
