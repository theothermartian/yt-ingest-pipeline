# YT Ingest Pipeline

A Firefox extension that bookmarks the current YouTube video and automatically runs it through a full **NotebookLM pipeline**: creates a notebook, generates a structured technical summary (Markdown with YAML frontmatter) and an infographic (PNG), then downloads both to a local output folder.

One click in the browser → files on disk, ready for Obsidian or any downstream tool.

## How it works

```
Firefox button click
  → native host saves URL to bookmarks.txt
  → fires on_bookmark.sh in background
      → skips if this video (by ID) was already summarized
      → creates NotebookLM notebook
      → adds YouTube URL as source, waits until it's indexed
      → generates technical summary report + infographic
      → polls until both are ready (~2–3 min)
      → downloads to output/YYYY-MM-DD_<title-slug>/
      → writes manifest.json
      → desktop notification: summary ready / failed (with reason)
```

## Prerequisites

- macOS (Apple Silicon assumed; see notes if Intel)
- Firefox 91+
- Node.js: `brew install node` — must end up at `/opt/homebrew/bin/node`
- Python 3 (ships with macOS)
- [`nlm` CLI](https://github.com/nnll/notebooklm-mcp-cli): `pip install notebooklm-mcp-cli` or `uv tool install notebooklm-mcp-cli`

After installing `nlm`, authenticate once:

```bash
nlm login
```

Sessions expire. Re-run `nlm login` if the pipeline logs an auth error — you'll also get a "YT Ingest failed" desktop notification.

Tested with `nlm` 0.15.4. That release changed `notebook create` to print JSON and reports finished custom reports as status `unknown`; the script handles both (and the older text format).

## Setup

### CRITICAL: where you clone matters

macOS TCC (Transparency, Consent, Control) blocks Firefox from launching the native messaging host if the project lives inside any of:

- `~/Documents`
- `~/Desktop`
- `~/Downloads`

If you try, `sendNativeMessage` fails silently in the popup and the Browser Console shows `Operation not permitted`.

Options:

1. **Recommended:** clone somewhere else, e.g. `~/yt-ingest-pipeline` or `~/code/yt-ingest-pipeline`. `install.sh` refuses to run from the protected folders.
2. **Alternative:** grant Firefox Full Disk Access in **System Settings → Privacy & Security → Full Disk Access**, then you can keep it in `~/Documents`.

### Install

```bash
cd ~                                 # or wherever, just not Documents/Desktop/Downloads
git clone <this-repo> yt-ingest-pipeline
cd yt-ingest-pipeline
./install.sh
```

`install.sh` rewrites the native-messaging manifest and the wrapper with absolute paths for this machine, then drops the manifest into `~/Library/Application Support/Mozilla/NativeMessagingHosts/`. Re-run it any time you move the folder.

### Load the extension in Firefox

There are two ways — pick one:

#### Option A: Unsigned XPI (persistent, survives restarts)

Requires `xpinstall.signatures.required` = `false` in `about:config` (Firefox Developer Edition and Nightly ship with this; on release Firefox you set it manually).

1. Build the XPI (requires Node.js, which you already have):
   ```bash
   npx web-ext build --source-dir extension
   ```
   This creates `web-ext-artifacts/yt_ingest_bookmarker-1.0.0.zip`.

2. **Fully quit Firefox** (Cmd+Q) and relaunch.
3. Open `about:addons` → gear icon (⚙) → **Install Add-on From File…**
4. Pick the `.zip` file produced above.

#### Option B: Temporary add-on (no build needed, reloads on restart)

1. **Fully quit Firefox** (Cmd+Q) and relaunch.
2. Go to `about:debugging` → **This Firefox** → **Load Temporary Add-on…**
3. Pick `extension/manifest.json`.

Visit a YouTube video page, click the toolbar icon, hit **Bookmark this video**.

## Output

Each bookmark creates a folder under `output/`:

```
output/
└── 2026-04-29_video-title-slug/
    ├── summary.md        ← structured Markdown with YAML frontmatter
    ├── infographic.png   ← visual overview
    ├── manifest.json     ← title, URL, notebook ID, artifact paths
    └── nlm_ops.log       ← raw nlm CLI output for debugging
```

`summary.md` is structured for Obsidian ingestion: it starts with YAML frontmatter (`title`, `source_url`, `topic_tags`, `difficulty_level`, `key_concepts`) followed by seven fixed sections (Concept Foundation, Technical Architecture, Key Contributions, Worked Example, Critical Analysis, Prerequisites, Practitioner Takeaways).

## Configuration

All pipeline settings live in `pipeline_config.json`:

| Key | Default | Description |
|-----|---------|-------------|
| `output_dir` | `~/yt-ingest-pipeline/output` | Where per-video folders are created |
| `log_file` | `~/yt-ingest-pipeline/ingest.log` | Append-only pipeline log |
| `skip_if_already_processed` | `true` | Skip a video (matched by video ID) that already has a complete output folder; failed runs stay retryable |
| `nlm.notebook_prefix` | `"YT:"` | Prefix for NotebookLM notebook titles |
| `nlm.delete_notebook_after_download` | `false` | Auto-delete the NLM notebook after downloading |
| `nlm.source_wait_seconds` | `35` | Fixed fallback wait, used only if `nlm source list` output can't be parsed |
| `nlm.source_ready_timeout_seconds` | `180` | Max time to poll for the video to finish indexing |
| `nlm.poll_interval_seconds` | `20` | How often to poll artifact status |
| `nlm.poll_max_attempts` | `45` | Timeout = interval × attempts (default 15 min) |
| `nlm.report.enabled` | `true` | Toggle report generation |
| `nlm.infographic.enabled` | `true` | Toggle infographic generation |
| `nlm.infographic.orientation` | `portrait` | `portrait` / `landscape` / `square` |
| `nlm.infographic.detail_level` | `detailed` | `concise` / `standard` / `detailed` |
| `nlm.infographic.style` | `professional` | `professional` / `sketch_note` / `bento_grid` / etc. |
| `nlm.infographic.focus` | *(prompt hint)* | Free-text hint for infographic content |

Paths support `~` and `$PIPELINE_DIR` tokens.

## File layout

```
yt-ingest-pipeline/
├── extension/                          # Firefox extension source
│   ├── manifest.json
│   ├── popup.html
│   ├── popup.js
│   ├── background.js
│   └── icons/icon48.png
├── native-host/
│   ├── yt_bookmark_host.js             # Node.js native messaging host
│   ├── host_wrapper.sh                 # Rewritten by install.sh (gitignored)
│   └── com.yt_ingest.bookmarker.json   # Rewritten by install.sh (gitignored)
├── install.sh                          # One-time setup (re-run if you move the folder)
├── on_bookmark.sh                      # Full NLM pipeline hook
├── pipeline_config.json                # All tunable settings
├── bookmarks.txt                       # Appended on each save (gitignored)
├── ingest.log                          # Pipeline log (gitignored)
├── host_debug.log                      # Native host debug trace (gitignored)
└── output/                             # Generated artifacts (gitignored)
    └── YYYY-MM-DD_<slug>/              # -2, -3… suffix if the folder already exists
        ├── summary.md
        ├── infographic.png
        ├── manifest.json
        └── nlm_ops.log
```

## Monitoring

Each run ends with a desktop notification — success, failure (with the reason from the log), or "already summarized". On macOS this uses `osascript`; on Linux, `notify-send` if installed. Notifications are best-effort: if no notifier is available nothing is shown and the pipeline is unaffected.

```bash
# Watch the pipeline in real time
tail -f ~/yt-ingest-pipeline/ingest.log

# If something fails, check the per-video nlm log
cat ~/yt-ingest-pipeline/output/<slug>/nlm_ops.log
```

## Architecture: why the native host has hardcoded paths

The XPI **is** standalone — `extension/*.js` has no hardcoded paths. But the extension can't write to the filesystem or run shell commands; that's Firefox's sandbox. To break out, it uses **Native Messaging**: it asks Firefox to launch a registered external program and pipes JSON to it over stdin/stdout.

For Firefox to know what program to launch, there's a manifest at `~/Library/Application Support/Mozilla/NativeMessagingHosts/com.yt_ingest.bookmarker.json`. By spec, its `path` field **must be absolute** — no `$PATH` lookup, no relative paths. That's why `install.sh` exists.

| Component | Hardcoded? | Why |
|---|---|---|
| Extension code | No | Truly portable |
| `yt_bookmark_host.js` PIPELINE_DIR | No — from `__dirname` | Self-locates at runtime |
| `host_wrapper.sh` paths | No — from `$SCRIPT_DIR` | Same |
| `/opt/homebrew/bin/node` in the wrapper | **Yes** | Firefox-spawned processes inherit a minimal `$PATH` — no shell, no nvm, no `.zshrc` |
| `path` in the installed NM manifest | **Yes** | Firefox spec requirement; written by `install.sh` at install time |

**Note on PATH in `on_bookmark.sh`:** Firefox GUI apps inherit only the launchd system PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). The script explicitly prepends `/opt/homebrew/bin`, `/usr/local/bin`, and `~/.local/bin` so that `nlm`, `python3`, and other tools are findable regardless of where they were installed.

**Note on stdout/stderr:** The native host spawns `on_bookmark.sh` with stdio inherited from Firefox. fd 1 is the live native-messaging pipe back to Firefox; Firefox closes its read end within milliseconds of getting the host's response. Any write to fd 1 after that point receives SIGPIPE, which with `set -euo pipefail` silently kills the script. The script seals both fds with `exec 1>/dev/null 2>/dev/null` as its first action. All output goes through `ingest.log` instead.

## bookmarks.txt format

Tab-separated, one entry per line:

```
2026-04-27T10:00:00Z\thttps://www.youtube.com/watch?v=abc123\tVideo Title Here
```

## Customizing on_bookmark.sh

`on_bookmark.sh` is the NLM pipeline by default. You can replace it with anything — it receives:

| Variable | Value |
|---|---|
| `$1` / `$URL` | YouTube URL |
| `$YT_TITLE` | Video title |
| `$YT_TIMESTAMP` | Timestamp |

Examples:

```bash
yt-dlp -x --audio-format mp3 -o "$PIPELINE_DIR/audio/%(id)s.%(ext)s" "$URL"
python3 "$PIPELINE_DIR/ingest.py" "$URL"
curl -s -X POST http://localhost:8080/ingest -d "{\"url\":\"$URL\"}" -H "Content-Type: application/json"
```

Keep `exec 1>/dev/null 2>/dev/null` at the top and write any output to a log file rather than stdout.

## Troubleshooting

**The popup says "Failed to contact native host" or "An unexpected error occurred."**

Check the **Browser Console** (Cmd+Shift+J), not the page console. Look for `Native messaging error:` or anything from `com.yt_ingest.bookmarker`.

**Browser Console says `Operation not permitted`**

The project is in a TCC-protected folder. Move it and re-run `./install.sh`, or grant Firefox Full Disk Access.

**You changed the manifest / reinstalled — nothing happens**

Firefox caches the native-host registry per session. **Fully quit Firefox** (Cmd+Q) and relaunch.

**`allowed_extensions` confusion**

`allowed_extensions` must contain the gecko ID `yt-ingest-bookmarker@local` from `extension/manifest.json`, **not** the brace-wrapped UUID Firefox shows in `about:debugging`.

**Node not found**

`install.sh` expects `/opt/homebrew/bin/node`. If yours is elsewhere (Intel Mac, nvm, asdf), edit `NODE_BIN` at the top of `install.sh` and re-run it.

**Pipeline starts but nlm fails**

Check `ingest.log` for the error message and `output/<slug>/nlm_ops.log` for the raw nlm output. Common causes:

- `nlm CLI not found` — `nlm` isn't in the PATH locations the script prepends. Find it with `which nlm` and add its directory to the `PATH=` line in `on_bookmark.sh`.
- `nlm session expired` — run `nlm login` and retry.
- `nlm notebook create returned an empty ID` / polls stuck on `unknown` — `nlm` changed its output format again. Compare the raw output in `nlm_ops.log` with the parsers in `on_bookmark.sh`.
- Artifact generation failed — the notebook is retained with its ID in the log; inspect it manually with `nlm studio status <id>`.

**Re-bookmarking does nothing / "already summarized"**

Videos that already have a complete output folder are skipped (matched by video ID). To regenerate, delete that folder under `output/` and bookmark again, or set `skip_if_already_processed` to `false`. Failed runs never count as complete, so they can always be retried by re-bookmarking.

A second bookmark of the same video while a run is still in progress is also skipped (lock: `output/.inflight-<video-id>`, auto-removed on exit, treated as stale after 30 min).
