# YT Ingest Pipeline

A Firefox extension that bookmarks the current YouTube video to a local text file and fires a bash hook so you can pipe the URL into yt-dlp, a transcript script, an LLM, a queue, or whatever you like.

## Prerequisites

- macOS (Apple Silicon assumed; see notes if Intel)
- Firefox 91+
- Node.js: `brew install node` — must end up at `/opt/homebrew/bin/node`

## Setup

### CRITICAL: where you clone matters

macOS TCC (Transparency, Consent, Control) blocks Firefox from launching the native messaging host if the project lives inside any of:

- `~/Documents`
- `~/Desktop`
- `~/Downloads`

If you try, `sendNativeMessage` fails silently in the popup and the Browser Console shows `Operation not permitted`.

You have two options:

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
   cd yt-ingest-pipeline
   npx web-ext build --source-dir extension
   ```
   This creates `web-ext-artifacts/yt_ingest_bookmarker-1.0.0.zip` (Firefox treats `.zip` as `.xpi`).

2. **Fully quit Firefox** (Cmd+Q) and relaunch.
3. Open `about:addons` → gear icon (⚙) → **Install Add-on From File…**
4. Pick the `.zip` file produced above.

The extension is now permanently installed and survives restarts.

#### Option B: Temporary add-on (no build needed, reloads on restart)

1. **Fully quit Firefox** (Cmd+Q) and relaunch.
2. Go to `about:debugging` → **This Firefox** → **Load Temporary Add-on…**
3. Pick `extension/manifest.json`.

Visit a YouTube video page, click the toolbar icon, hit **Bookmark this video**.

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
│   ├── yt_bookmark_host.js             # The active Node.js native host
│   ├── host_wrapper.sh                 # Bash wrapper that execs node (rewritten by install.sh)
│   └── com.yt_ingest.bookmarker.json   # Source copy of NM manifest (rewritten by install.sh)
├── install.sh                          # One-time setup script (re-run if you move the folder)
├── on_bookmark.sh                      # Bash hook — edit this for your pipeline
├── bookmarks.txt                       # Appended on each save
├── ingest.log                          # Written by on_bookmark.sh
└── host_debug.log                      # Wrapper + host debug trace
```

## Architecture: why the native host has hardcoded paths

A reasonable question when reading this code: "If the XPI is a standalone bundle, why are there absolute paths anywhere?"

The XPI **is** standalone — `extension/*.js` has no hardcoded paths. But the extension can't write to the filesystem or run shell commands; that's Firefox's sandbox. To break out, it uses **Native Messaging**: it asks Firefox to launch a registered external program and pipes JSON to it over stdin/stdout. The XPI references that program only by name (`com.yt_ingest.bookmarker`).

For Firefox to know what that name maps to on this machine, there's a separate manifest at `~/Library/Application Support/Mozilla/NativeMessagingHosts/com.yt_ingest.bookmarker.json`. By spec, its `path` field **must be absolute** — there's no `$PATH` lookup, no "relative to the XPI" option, and the XPI cannot install this file itself (it's sandboxed). That's the entire reason `install.sh` exists as a separate setup step.

So:

| Component | Hardcoded? | Why |
|---|---|---|
| The XPI / extension code | No | Truly portable. Reload it on any machine. |
| `yt_bookmark_host.js` PIPELINE_DIR | No — derived from `__dirname` | Self-locates wherever the project lives. |
| `host_wrapper.sh` paths | No — derived from `$SCRIPT_DIR` | Same. |
| `/opt/homebrew/bin/node` in the wrapper | **Yes** | Firefox-spawned processes inherit a minimal `$PATH` — no shell, no nvm, no `.zshrc`. `node` alone would fail with "command not found". |
| `path` field in the installed NM manifest | **Yes** | Firefox spec requires an absolute path. `install.sh` writes this dynamically based on where you cloned, so it isn't committed-hardcoded; it's install-time-resolved. |

Short version: the XPI is portable. The native host is **machine-specific by design** — that's the price of breaking out of the browser sandbox, and `install.sh` is what makes it not painful.

## bookmarks.txt format

Tab-separated, one entry per line:

```
2026-04-27T10:00:00Z\thttps://www.youtube.com/watch?v=abc123\tVideo Title Here
```

## Customizing on_bookmark.sh

The hook runs in the background (detached) after each successful bookmark. It receives:

| Variable | Value |
|---|---|
| `$1` / `$YT_URL` | YouTube URL |
| `$YT_TITLE` | Video title |
| `$YT_TIMESTAMP` | ISO 8601 timestamp |

Examples (already commented in the file):

```bash
yt-dlp -x --audio-format mp3 -o "$PIPELINE_DIR/audio/%(id)s.%(ext)s" "$URL"
python3 "$PIPELINE_DIR/ingest.py" "$URL"
curl -s -X POST http://localhost:8080/ingest \
     -d "{\"url\": \"$URL\"}" -H "Content-Type: application/json"
```

The hook uses `dirname "$0"` for paths, so it stays portable.

## Troubleshooting

**The popup says "Failed to contact native host" or "An unexpected error occurred."**

The popup's Web Console only shows generic errors. The real reason is in the **Browser Console**:

- macOS: **Cmd+Shift+J** (Tools → Browser Tools → Browser Console)
- Look for lines starting with `Native messaging error:` or anything from `com.yt_ingest.bookmarker`.

**Browser Console says `Operation not permitted`**

The project is in a TCC-protected folder (`~/Documents`, `~/Desktop`, `~/Downloads`). Move it elsewhere and re-run `./install.sh`, or grant Firefox Full Disk Access. See the Setup section.

**You changed the manifest / reinstalled — nothing happens**

Firefox caches the native-host registry per session. **Fully quit Firefox** (Cmd+Q) and relaunch. Reloading the extension in `about:debugging` is not enough.

**`allowed_extensions` confusion**

The manifest's `allowed_extensions` must contain the gecko ID from `extension/manifest.json` (`yt-ingest-bookmarker@local`), **not** the brace-wrapped UUID Firefox shows in `about:debugging`. The UUID is internal and changes per profile; it does not authorize anything.

**Node not found**

`install.sh` requires `/opt/homebrew/bin/node`. If yours lives elsewhere (Intel Mac, nvm, asdf, etc.), edit `NODE_BIN` at the top of `install.sh` and re-run it.

**Inspect the host's own log**

`host_debug.log` in the project root records every wrapper launch and every message received/error thrown by the Node host. `tail -f host_debug.log` while clicking the button is usually enough to see what's wrong.
