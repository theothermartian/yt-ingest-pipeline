#!/usr/bin/env bash
# Called by the native host after each bookmark.
# Args: $1 = YouTube URL
# Env:  YT_URL, YT_TITLE, YT_TIMESTAMP

set -euo pipefail

URL="$1"
PIPELINE_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$PIPELINE_DIR/ingest.log"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Bookmarked: $URL  |  $YT_TITLE" >> "$LOG"

# ── Add your pipeline commands below ────────────────────────────────────────
# Example: download audio with yt-dlp
# yt-dlp -x --audio-format mp3 -o "$PIPELINE_DIR/audio/%(id)s.%(ext)s" "$URL"

# Example: run a Python ingest script
# python3 "$PIPELINE_DIR/ingest.py" "$URL"

# Example: send to a queue / API
# curl -s -X POST http://localhost:8080/ingest -d "{\"url\": \"$URL\"}" \
#      -H "Content-Type: application/json"
# ────────────────────────────────────────────────────────────────────────────

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Hook done." >> "$LOG"
