# leak-guard

Keeps names that must not be published out of a public repository: in files, file names, commit messages, commit
authors and the whole history. The list of private names never enters the repository, and a match is reported by
the pattern's position, never by the matched text, because the CI logs of a public repository are public too.

Works with: any git repository; the hooks are plain git hooks and the CI job is GitHub Actions. This repository is
its first user: its own hooks and CI run this scanner.

## What it checks

| Where | Hook or job | Patterns |
|---|---|---|
| staged files and their names | pre-commit | public, and private if configured |
| the commit message | commit-msg | public, and private if configured |
| every commit, message, diff and author on every ref | pre-push, CI | public and private, private required |
| the tracked tree | CI | public and private, private required |

Public patterns are built in: absolute home paths, e-mail addresses other than GitHub noreply and `example.*`, and
RFC 1918 addresses. Private patterns are yours: one case-insensitive regular expression per line, in a git-ignored
`.leakguard.local` locally and in a `LEAKGUARD_PATTERNS` repository secret in CI. Intentional public matches go in
a committed `.leakguard-allow` as exact `<path> <pattern-id>` pairs; a private match can never be allowed.

## Install

Requires Python 3.9 or newer and git.

```sh
sh tools/leak-guard/install.sh path/to/your-repo
```

It copies the scanner and the three hooks into `path/to/your-repo/.leak-guard/`, creates an empty
`.leakguard-allow` if there is none, adds `.leakguard.local` to `.gitignore`, and prints the next steps. It changes
no git configuration; enable the hooks yourself, once per clone, because git does not carry hooks across clones:

```sh
git -C path/to/your-repo config core.hooksPath .leak-guard/hooks
```

If the repository already uses `core.hooksPath` for other hooks, call the three `.leak-guard/hooks` scripts from
yours instead. For CI, copy [`ci/leak-scan.yml`](ci/leak-scan.yml) into `.github/workflows/` and add the
`LEAKGUARD_PATTERNS` secret; the job fails when the secret is missing. Commit `.leak-guard/` and `.leakguard-allow`;
never commit `.leakguard.local`.

## Usage

```sh
python3 .leak-guard/leak_scan.py --tree --require-private      # every tracked file
python3 .leak-guard/leak_scan.py --history --require-private   # every commit on every ref
python3 .leak-guard/leak_scan.py --tree --reveal               # locally: show the matched text and paths
```

| Exit code | Meaning |
|---|---|
| 0 | nothing found |
| 1 | findings, one per line: `path:line: pattern-id`, or `commit:path:line: pattern-id` in history |
| 2 | the scan could not run: not a repository, a shallow clone, a bad pattern, private patterns required but none |

A leak that was already pushed stays in forks and caches: the fix is a history rewrite, and the secret or name
should be treated as published.

## Test

```sh
python3 -m unittest discover -s tools/leak-guard/tests -t tools/leak-guard/tests
```
