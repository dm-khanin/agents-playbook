---
name: write-reliable-hooks
description: Write or debug an agent hook so it cannot block the session, fails visibly and does what you think. Use when adding a hook to Claude Code or to a harness that runs Claude Code hooks, when a hook seems not to fire, fires twice or blocks prompts, or when a hook needs state, network access or git.
---

# Write reliable agent hooks

Works with: Claude Code (this skill loads; the behaviour below was measured on Claude Code 2.1 releases in October
2026, the exit codes on macOS and Debian; re-check on a newer version); OpenCode (loads from `~/.agents/skills`
in v2.0.26); DeepSeek Harness through its Claude Code hook bridge, and Gemini CLI, whose hook events have other
names (format-compatible, untested).

A hook runs on every matching event of every session, unattended. A broken hook is not a failed command you
notice: it is a session that silently loses context, or one that cannot take a prompt at all.

## Behaviour to design for

- **Exit code 2 blocks.** From a prompt hook it rejects the prompt; from a pre-tool hook it blocks the tool. And
  `python3 missing.py` itself exits 2, so a Python hook whose script moved blocks every prompt in every session
  (`node` exits 1, and bash and zsh exit 127, which do not block; dash, the `/bin/sh` of Debian and Ubuntu,
  exits 2 and does block).
- **The payload's working directory is where the command ended.** After `cd sub && make`, a post-tool hook sees
  `sub`; applying the command's relative `cd` to that directory again lands somewhere else. A failed command's
  payload can still carry the starting directory.
- **Prompt hooks also fire on subagent hand-backs**, which arrive as user turns. A hook that reacts to links or ids
  in prompts reacts to a subagent's report too.
- **Settings edits apply live**, and the first call after an edit can race it. Re-test before concluding that a
  hook does not fire.
- **A command filter such as `if: "Bash(git push *)"`** fires for plain, piped, chained and redirected forms of the
  command, and not for the same text inside a heredoc body.

## The kit

1. **Never block by accident.** End every hook command with `|| true` unless blocking is the hook's job.
2. **Fail into a log, surface it later.** Write errors to the hook's own log file, and let a session-start hook
   report entries newer than its last run. A hook that fails silently forever is worse than one that fails loudly
   once.
3. **A kill switch.** One environment variable turns the hook into a no-op, so a broken hook can be bypassed
   without editing settings in the middle of an incident.
4. **A time budget inside the timeout.** Give the work less time than the harness gives the hook and stop cleanly
   when it runs out; a hook killed at the timeout leaves half-written state.
5. **Nothing interactive.** `GIT_TERMINAL_PROMPT=0`, `ssh -o BatchMode=yes`, no pagers. A password prompt hangs the
   hook until it is killed.
6. **Cap injected context.** Truncate what the hook adds to the conversation to a fixed size and say so.
7. **State survives concurrency.** Several sessions run the same hook at once: take a lock (`flock`), write a
   temporary file, `fsync` it, then rename it over the old one. macOS has no `flock` command: use `fcntl.flock`
   from Python, or an atomic `mkdir` as the lock.
8. **Guard the entry point.** If the hook's own code cannot load after an update, catch that where the hook starts
   and log it, instead of letting the interpreter's exit code decide what the harness does.

## Prove it

- **That it fires:** prefix the hook command with a temporary sentinel (`echo fired >> /tmp/hook-sentinel;`),
  trigger it with a harmless matching call (`git push --help`), read the sentinel, remove the prefix.
- **That its test can fail:** feed the script a recorded payload on stdin, assert on stdout and the exit code, then
  break the code and watch the test go red.
- **Traps that fake a pass:** zsh does not word-split `$var`, so `$cmd args` runs a command named after the whole
  string and a loop over `$pairs` runs once; run such loops under `bash -c` with one case that must differ. Apple's
  system Python keeps bytecode in a shared cache keyed by path, modification time and size, so a mutant of the
  same size written within the same second can run stale code: write mutants to a fresh path, or set
  `PYTHONDONTWRITEBYTECODE=1` for every run, the original included.
