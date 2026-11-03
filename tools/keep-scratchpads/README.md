# keep-scratchpads

Keeps Claude Code session scratchpads from being deleted by the macOS `/tmp` clean-up, so a session resumed days
later still finds its intermediate files.

Works with: Claude Code on macOS.

## Why

- Claude Code gives each session a scratchpad under `/private/tmp/claude-<uid>/<project>/<session>/`.
- macOS runs a daily clean-up (`com.apple.tmp_cleaner`, at midnight) that deletes files in `/private/tmp` whose
  access, modification and change times are all older than 3 days.
- A session paused over a long weekend comes back to an empty scratchpad, and whatever a summary pointed at is
  gone.

## What it does

Once a day, and when it is loaded, a LaunchAgent runs `keep-scratchpads.sh`. For each scratchpad the script finds
the session's transcript at `~/.claude/projects/<project>/<session>.jsonl`. If that transcript changed in the last
30 days, it refreshes the access time of every file in the scratchpad, which is enough to fail the all-three-older test.
Modification times stay as they are.
Scratchpads of older sessions, and scratchpads with no transcript, are left for the clean-up.

It only postpones deletion: anything you need to keep belongs in a real directory, not in a scratchpad.

| Variable | Default | Meaning |
|---|---|---|
| `KEEP_DAYS` | `30` | How recent a transcript must be for its scratchpad to be kept |
| `KEEP_SCRATCHPADS_ROOT` | `/private/tmp/claude-$(id -u)` | Where the scratchpads live |
| `KEEP_SCRATCHPADS_PROJECTS` | `~/.claude/projects` | Where the transcripts live |

## Install

```sh
mkdir -p ~/.agents/tools ~/Library/LaunchAgents
cp -R tools/keep-scratchpads ~/.agents/tools/
sed "s|__HOME__|$HOME|" ~/.agents/tools/keep-scratchpads/keep-scratchpads.plist \
  > ~/Library/LaunchAgents/local.keep-scratchpads.plist
launchctl load ~/Library/LaunchAgents/local.keep-scratchpads.plist
```

launchd does not expand `~` or `$HOME`, so the install step writes your home directory into the plist. The job
runs at 23:30, before the clean-up at midnight, and once at load. A Mac that is asleep at 23:30 runs it on wake.

Check it ran: `launchctl list | grep keep-scratchpads` shows exit status `0`.

Remove it: `launchctl unload ~/Library/LaunchAgents/local.keep-scratchpads.plist`, then delete the plist.

## Test

```sh
python3 -m unittest discover -s tools/keep-scratchpads/tests -t tools/keep-scratchpads/tests
```

The tests build a scratchpad root and a projects directory in a temporary directory and point the script at them.
