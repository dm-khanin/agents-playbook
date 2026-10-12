# notify-telegram

Answer an agent's permission prompt from your phone. When Claude Code asks to run a tool, this hook sends the
request to a Telegram chat with three buttons: **Allow**, **Always Allow** (accepts the rules Claude Code
suggested) and **Deny**. If nobody answers before the timeout, the hook steps aside and the normal terminal prompt
appears; if you answer in the terminal instead, the next request marks the old Telegram message as answered there.

Works with: Claude Code only. DeepSeek Harness's hook bridge and Gemini CLI have no permission-request event;
OpenCode would need a JavaScript plugin.

## Setup

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. Send the bot any message, then read your chat id from
   `https://api.telegram.org/bot<token>/getUpdates` (`message.chat.id`).
3. Store both in the env file, readable only by you:

   ```sh
   mkdir -p ~/.config/agents-playbook
   umask 077
   cat > ~/.config/agents-playbook/telegram.env <<'ENV'
   TELEGRAM_BOT_TOKEN=<token>
   TELEGRAM_CHAT_ID=<chat id>
   ENV
   ```

   Or export `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` directly. `TELEGRAM_HOOK_ENV_FILE` points the hook at
   another env file; `TELEGRAM_HOOK_TIMEOUT` sets the wait in seconds (default 120).
4. Install the script and merge [`hooks.json`](hooks.json) into the `hooks` key of `~/.claude/settings.json`:

   ```sh
   mkdir -p ~/.agents/hooks
   cp -R hooks/notify-telegram ~/.agents/hooks/
   ```

Requires `bash`, `curl` and `jq`.

## Security

Anyone who can press the buttons in that chat can approve tool calls on your machine. Use a private chat with the
bot, never a group. The message shows the tool, its command or file path, the working directory's name and the
start of the session's first prompt.

## Test

```sh
python3 -m unittest discover -s hooks/notify-telegram/tests -t hooks/notify-telegram/tests
```

The tests replace `curl` with [`tests/fake_curl.py`](tests/fake_curl.py), a stand-in for the Telegram API, so they
run offline.
