#!/usr/bin/env python3
"""Stand-in for curl that plays the Telegram Bot API for notify-telegram.sh tests.

Environment:
  FAKE_TG_STATE     directory for the call log and the captured request id
  FAKE_TG_SCENARIO  allow | always | deny | silent | foreign: what the user "presses"
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path


def main(argv: list[str]) -> int:
    state = Path(os.environ["FAKE_TG_STATE"])
    state.mkdir(parents=True, exist_ok=True)
    url = next((a for a in argv if a.startswith("http")), "")
    payload_text = argv[argv.index("-d") + 1] if "-d" in argv else "{}"
    try:
        payload = json.loads(payload_text)
    except json.JSONDecodeError:
        payload = {}
    method = url.rsplit("/", 1)[-1]
    with (state / "calls.log").open("a", encoding="utf-8") as log:
        log.write(json.dumps({"method": method, "payload": payload}) + "\n")

    if method == "sendMessage":
        callback = payload["reply_markup"]["inline_keyboard"][0][0]["callback_data"]
        (state / "req").write_text(callback.rsplit(":", 1)[0], encoding="utf-8")
        print(json.dumps({"ok": True, "result": {"message_id": 7}}))
    elif method == "getUpdates":
        scenario = os.environ.get("FAKE_TG_SCENARIO", "silent")
        req_file = state / "req"
        if payload.get("offset") == -1 or scenario == "silent" or not req_file.exists():
            time.sleep(0.2)
            print(json.dumps({"ok": True, "result": []}))
        else:
            if scenario == "foreign":
                data = "perm_1_1:allow"  # a button from some other, older request
            else:
                data = f"{req_file.read_text(encoding='utf-8')}:{scenario}"
            update = {"update_id": 41, "callback_query": {"id": "cb-1", "data": data}}
            print(json.dumps({"ok": True, "result": [update]}))
    else:
        print(json.dumps({"ok": True, "result": True}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
