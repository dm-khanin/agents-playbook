#!/bin/bash
# usage-guard notifier: sends $1 as one Telegram message and prints the HTTP status for the guard's event log.
#
# Credentials come from TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID, or from the env file below (keep it chmod 600),
# the same file hooks/notify-telegram reads. Without them it prints "no-credentials" and exits 0, so a missing
# file never breaks a hook. The token reaches curl as a config on stdin, never as an argument other processes
# could read.
ENV_FILE="${TELEGRAM_HOOK_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/agents-playbook/telegram.env}"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"
if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
  echo "no-credentials"
  exit 0
fi

printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$BOT_TOKEN" |
  curl -s -m 20 -o /dev/null -w '%{http_code}' -K - -X POST \
    --data-urlencode "chat_id=${CHAT_ID}" --data-urlencode "text=$1"
