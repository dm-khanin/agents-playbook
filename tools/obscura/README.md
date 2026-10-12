# Obscura

[Obscura](https://github.com/h4ckf0r0day/obscura) is a headless browser written in Rust, with its own DOM, V8 and
layout engine instead of Chromium. It is fast and light for reading JavaScript-heavy pages: a CLI
(`obscura fetch <url> --dump markdown`), a Chrome DevTools Protocol server for Puppeteer and Playwright, and an MCP
server with about 37 `browser_*` tools.

Works with: Claude Code (used). Gemini CLI, OpenCode, DeepSeek Harness through the MCP snippets below
(format-compatible, untested).

## Choosing a build

- **Homebrew** builds Obscura from source with default features, and the CLI's default feature set is empty, so
  the bottle has no renderer: no screenshots, no PDF, no layout geometry.
- **Release archives** include the renderer.
- **`-stealth` release archives** add TLS impersonation and tracker blocking, but only when `--stealth` is passed
  at run time. Without the flag they use the same transport as the plain build, so the stealth archive is a
  superset you can install by default.

## Install from a release

```sh
tag=v0.2.4   # check the latest at https://github.com/h4ckf0r0day/obscura/releases
asset=obscura-aarch64-macos-stealth.tar.gz
dir=$(mktemp -d) && cd "$dir"
curl -fsSLO "https://github.com/h4ckf0r0day/obscura/releases/download/$tag/$asset"
shasum -a 256 "$asset"
gh release view "$tag" -R h4ckf0r0day/obscura --json assets --jq ".assets[] | select(.name==\"$asset\") | .digest"
tar tzf "$asset"          # expect two plain files: obscura, obscura-worker
tar xzf "$asset"
install -m 755 obscura obscura-worker ~/.local/bin/
obscura --version
```

Compare the two hashes before extracting. Keep `obscura` and `obscura-worker` in the same directory: the
parallel `scrape` command starts the worker from there. Updates are manual: repeat with the new tag.

## MCP setup

Claude Code:

```sh
claude mcp add -s user obscura -- obscura mcp
```

Gemini CLI, `~/.gemini/settings.json`:

```json
{ "mcpServers": { "obscura": { "command": "obscura", "args": ["mcp"] } } }
```

OpenCode, `~/.config/opencode/opencode.json`:

```json
{ "mcp": { "obscura": { "type": "local", "command": ["obscura", "mcp"], "enabled": true } } }
```

DeepSeek Harness, a row in `~/.dsh/cordis.patch.yml` (untested; check the patch syntax with
`dsh <profile> --dump-config`):

```yaml
- id: mcp-obscura
  name: '@deepseek-ai/dsh-mcp-client'
  config: { serverName: obscura, transport: stdio, command: obscura, args: [mcp] }
```

## Fonts

Obscura scans no system fonts, so Chinese, Japanese, Korean, Thai and Devanagari text renders as boxes in
screenshots. [`make_font_kit.py`](make_font_kit.py) copies a curated set of macOS system fonts into
`~/.local/share/obscura/fonts` (or a directory you pass):

```sh
python3 tools/obscura/make_font_kit.py
obscura serve --font-dir ~/.local/share/obscura/fonts
```

- The files are copied, not linked: the font loader skips symlinks on purpose.
- Measured on one multi-script test page: 45 MB resident without extra fonts, 138 MB with the kit, 827 MB when
  pointing `--font-dir` at the whole system font directory. The whole directory also lets font fallback pick a
  system Arabic font that breaks letter joining, which the built-in font gets right.
- In v0.2.4 only `serve` accepts `--font-dir`; the MCP server gains it in the next release. Until then, MCP
  screenshots of CJK text show boxes, while text extraction is unaffected.

## Traps

- Loopback and private-network addresses are blocked unless you pass `--allow-private-network`.
- Markdown and snapshot output can include elements hidden by CSS, such as a duplicated mobile menu.
- Fixed and sticky elements can overlap after scrolling. For checks that must match Chrome pixel for pixel, use
  Playwright.

## Test

```sh
python3 -m unittest discover -s tools/obscura/tests -t tools/obscura/tests
```
