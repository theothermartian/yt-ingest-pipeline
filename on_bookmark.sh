#!/usr/bin/env bash
# on_bookmark.sh — NotebookLM ingest pipeline
# Called by the native host after each YouTube bookmark.
# Args: $1 = YouTube URL
# Env:  YT_TITLE, YT_TIMESTAMP

set -euo pipefail

# When spawned from the Firefox native host, fd 1 is the live write end of the
# native-messaging pipe. Firefox closes its read end within milliseconds of
# receiving the host's response — any tee/echo write after that gets SIGPIPE,
# which with set -euo pipefail kills the script silently. Seal both fds now.
exec 1>/dev/null 2>/dev/null

URL="$1"
PIPELINE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$PIPELINE_DIR/pipeline_config.json"

# Firefox spawns processes with a minimal PATH — explicitly add homebrew and
# common local-bin locations so that nlm, python3, etc. are all findable.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:$PATH"

# ── Config reader ─────────────────────────────────────────────────────────────
# Usage: cfg "some.nested.key"  →  prints the value (expands ~, $PIPELINE_DIR)
cfg() {
    python3 - "$CONFIG_FILE" "$1" "$PIPELINE_DIR" <<'PYEOF'
import json, sys, os
config_file, key, pipeline_dir = sys.argv[1], sys.argv[2], sys.argv[3]
with open(config_file) as f:
    data = json.load(f)
val = data
for part in key.split('.'):
    val = val[part]
if isinstance(val, bool):
    print(str(val).lower())
elif isinstance(val, str):
    val = os.path.expanduser(val)
    val = val.replace('$PIPELINE_DIR', pipeline_dir)
    print(val)
else:
    print(val)
PYEOF
}

OUTPUT_BASE=$(cfg "output_dir")
LOG_FILE=$(cfg "log_file")
NB_PREFIX=$(cfg "nlm.notebook_prefix")
DELETE_NB=$(cfg "nlm.delete_notebook_after_download")
SOURCE_WAIT=$(cfg "nlm.source_wait_seconds")
POLL_INTERVAL=$(cfg "nlm.poll_interval_seconds")
POLL_MAX=$(cfg "nlm.poll_max_attempts")
REPORT_ENABLED=$(cfg "nlm.report.enabled")
INF_ENABLED=$(cfg "nlm.infographic.enabled")
INF_ORIENTATION=$(cfg "nlm.infographic.orientation")
INF_DETAIL=$(cfg "nlm.infographic.detail_level")
INF_STYLE=$(cfg "nlm.infographic.style")
INF_FOCUS=$(cfg "nlm.infographic.focus")

# ── Logging ───────────────────────────────────────────────────────────────────
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() {
    echo "[$(ts)] $*" >> "$LOG_FILE"
    case "$*" in ERROR:*) LAST_ERROR="${*#ERROR: }" ;; esac
}

# ── Desktop notification (best effort) ────────────────────────────────────────
# Runs detached with all output discarded: a missing notifier, no display
# (headless Linux), or a hung D-Bus can never fail or block the pipeline.
notify() {
    local title="$1" msg="$2"
    (
        case "$(uname -s)" in
            Darwin)
                command -v osascript >/dev/null 2>&1 && osascript \
                    -e 'on run argv' \
                    -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
                    -e 'end run' "$title" "$msg"
                ;;
            Linux)
                command -v notify-send >/dev/null 2>&1 && notify-send "$title" "$msg"
                ;;
        esac
    ) >/dev/null 2>&1 </dev/null &
    return 0
}

LAST_ERROR=""
VIDEO_LOCK=""
on_exit() {
    local code=$?
    [ -n "$VIDEO_LOCK" ] && rm -rf "$VIDEO_LOCK"
    if [ "$code" -ne 0 ]; then
        notify "YT Ingest failed" "${LAST_ERROR:-See ingest.log} — ${YT_TITLE:-$URL}"
    fi
}
trap on_exit EXIT

# ── Error trap ────────────────────────────────────────────────────────────────
on_error() {
    local line="$1" code="$2"
    log "ERROR: pipeline failed at line $line (exit code $code)"
    if [ -n "${NB_ID:-}" ]; then
        log "Notebook $NB_ID was NOT deleted — clean up manually:"
        log "  nlm notebook delete $NB_ID --confirm"
    fi
}
trap 'on_error $LINENO $?' ERR

# ── Skip videos already summarized ────────────────────────────────────────────
# Matched by YouTube video ID (so &t=… etc. don't matter). Only a run whose
# manifest and artifacts all exist counts — failed runs stay retryable.
VIDEO_ID=$(python3 -c '
import sys, urllib.parse as u
p = u.urlparse(sys.argv[1])
print((u.parse_qs(p.query).get("v") or [""])[0])
' "$URL")
mkdir -p "$OUTPUT_BASE"
SKIP_DONE=$(cfg "skip_if_already_processed" 2>/dev/null || echo true)
if [ -n "$VIDEO_ID" ] && [ "$SKIP_DONE" != "false" ]; then
    DONE_DIR=$(python3 - "$OUTPUT_BASE" "$VIDEO_ID" <<'PYEOF'
import glob, json, os, sys, urllib.parse as u
base, vid = sys.argv[1], sys.argv[2]
for mf in sorted(glob.glob(os.path.join(base, "*", "manifest.json"))):
    try:
        with open(mf) as fh:
            m = json.load(fh)
    except Exception:
        continue
    q = u.parse_qs(u.urlparse(m.get("url", "")).query)
    if (q.get("v") or [""])[0] != vid:
        continue
    d = os.path.dirname(mf)
    paths = [os.path.join(d, f) for f in m.get("artifacts", {}).values()]
    if all(os.path.isfile(p) and os.path.getsize(p) > 0 for p in paths):
        print(d)
        break
PYEOF
)
    if [ -n "$DONE_DIR" ]; then
        log "SKIP: $URL already summarized in $DONE_DIR"
        notify "YT Ingest: already summarized" "${YT_TITLE:-$URL}"
        exit 0
    fi

    # Guard against double-bookmarking while a run for this video is in flight.
    # mkdir is atomic; locks older than 30 min are treated as stale.
    LOCK_PATH="${OUTPUT_BASE}/.inflight-${VIDEO_ID}"
    find "$LOCK_PATH" -maxdepth 0 -mmin +30 -exec rm -rf {} + 2>/dev/null || true
    if ! mkdir "$LOCK_PATH" 2>/dev/null; then
        log "SKIP: $URL is already being processed by another run"
        exit 0
    fi
    VIDEO_LOCK="$LOCK_PATH"
fi

# ── Output folder ─────────────────────────────────────────────────────────────
DATE_PREFIX=$(date -u +%Y-%m-%d)
TITLE_SLUG=$(printf '%s' "$YT_TITLE" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' \
    | sed 's/^-//; s/-$//' \
    | cut -c1-55)
OUT_DIR="${OUTPUT_BASE}/${DATE_PREFIX}_${TITLE_SLUG}"
# Re-bookmarking the same video on the same day must not clobber the earlier run.
if [ -e "$OUT_DIR" ]; then
    n=2
    while [ -e "${OUT_DIR}-${n}" ]; do n=$((n + 1)); done
    OUT_DIR="${OUT_DIR}-${n}"
fi
OPS_LOG="${OUT_DIR}/nlm_ops.log"

mkdir -p "$OUT_DIR"

log "=================================================================="
log "NLM PIPELINE START"
log "URL       : $URL"
log "Title     : $YT_TITLE"
log "Timestamp : $YT_TIMESTAMP"
log "Output    : $OUT_DIR"
log "=================================================================="

# ── Preflight checks ──────────────────────────────────────────────────────────
if ! command -v nlm >/dev/null 2>&1; then
    log "ERROR: nlm CLI not found in PATH: $PATH"
    log "Install nlm and ensure it is on PATH before using this pipeline."
    exit 1
fi

if ! nlm login --check >>"$OPS_LOG" 2>&1; then
    log "ERROR: nlm session expired or not authenticated."
    log "Run: nlm login   (then retry by re-bookmarking the video)"
    exit 1
fi
log "Auth: OK"

# ── Create notebook ───────────────────────────────────────────────────────────
NB_TITLE="${NB_PREFIX} ${YT_TITLE}"
log "Creating notebook: $NB_TITLE"
NB_CREATE_OUT=$(nlm notebook create "$NB_TITLE" 2>>"$OPS_LOG")
printf '%s\n' "$NB_CREATE_OUT" >>"$OPS_LOG"
# nlm >=0.15 emits JSON ({"notebook_id": ...}) when stdout is not a TTY;
# older versions print a "  ID: <uuid>" line. Handle both.
NB_ID=$(printf '%s\n' "$NB_CREATE_OUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("notebook_id") or d.get("id") or "")
except Exception:
    pass
' 2>/dev/null)
[ -z "$NB_ID" ] && NB_ID=$(printf '%s\n' "$NB_CREATE_OUT" | awk '/ID:/{print $NF}')
if [ -z "$NB_ID" ]; then
    log "ERROR: nlm notebook create returned an empty ID. Check $OPS_LOG"
    exit 1
fi
log "Notebook ID: $NB_ID"

# ── Add YouTube source ────────────────────────────────────────────────────────
log "Adding source: $URL"
nlm source add "$NB_ID" --youtube "$URL" >>"$OPS_LOG" 2>&1
# Poll until every source reports status 2 (ready) instead of a blind sleep.
# Prints: ready | waiting:<statuses> | unparseable
_SOURCE_READY_PY=$(cat <<'PYEOF'
import json, sys
try:
    items = json.load(sys.stdin)
    statuses = [s.get("status") for s in items]
    if statuses and all(st == 2 for st in statuses):
        print("ready")
    else:
        print("waiting:" + ",".join(str(st) for st in statuses))
except Exception:
    print("unparseable")
PYEOF
)
SOURCE_TIMEOUT=$(cfg "nlm.source_ready_timeout_seconds" 2>/dev/null || echo 180)
log "Source queued. Waiting for NotebookLM to index the video (max ${SOURCE_TIMEOUT}s)..."
waited=0
while true; do
    SRC_STATE=$(nlm source list "$NB_ID" --json 2>>"$OPS_LOG" \
        | python3 -c "$_SOURCE_READY_PY" || echo unparseable)
    if [ "$SRC_STATE" = "ready" ]; then
        log "Source indexed after ${waited}s."
        break
    fi
    if [ "$SRC_STATE" = "unparseable" ]; then
        # nlm output changed shape — fall back to the old fixed wait.
        log "WARN: could not read source status; falling back to fixed ${SOURCE_WAIT}s wait."
        sleep "$SOURCE_WAIT"
        break
    fi
    if [ "$waited" -ge "$SOURCE_TIMEOUT" ]; then
        log "WARN: source not ready after ${SOURCE_TIMEOUT}s ($SRC_STATE); continuing anyway."
        break
    fi
    sleep 5
    waited=$((waited + 5))
done

# ── Generate report ───────────────────────────────────────────────────────────
if [ "$REPORT_ENABLED" = "true" ]; then
    log "Requesting technical summary report..."

    REPORT_PROMPT=$(cat <<'PROMPT'
You are a technical educator preparing materials for a graduate-level computer science or engineering course. Using ONLY information explicitly stated in the source video, produce a structured technical deep-dive in valid Markdown.

Begin with this YAML frontmatter block, filled from the video content:

---
title: "<exact video title>"
source_url: "<video URL>"
topic_tags: [<3–6 lowercase tags inferred strictly from video content>]
difficulty_level: "<undergraduate | graduate | research>"
key_concepts: [<3–5 primary technical concepts covered>]
---

Then produce the following sections using ## Markdown headers, exactly as written below:

## 1. Concept Foundation
Two to three paragraphs building the topic from first principles. Assume the reader has strong CS or engineering fundamentals but has never encountered this specific domain before. Define every key technical term in **bold** on first use. Do not assume the reader has prior exposure to the subject.

## 2. Technical Architecture & Methodology
A thorough, structured walkthrough of the systems, algorithms, frameworks, or methods presented. For every significant component state: (a) what it is, (b) how it interacts with adjacent components, and (c) why this design choice was made — use only reasons the source explicitly provides. Include data flows, interface contracts, or time and space complexity where the source states them. Use sub-headings (###) to separate major subsystems if there are more than three.

## 3. Key Contributions & Insights
A bulleted list. Each bullet must include: (a) the specific contribution or finding, (b) why it is significant according to the source, and (c) how it differs from or improves upon prior approaches explicitly mentioned in the source. If no prior work is compared in the source, write "No explicit comparison made in source."

## 4. Worked Example
A concrete worked example, step-by-step calculation, or grounding analogy that makes the central mechanism intuitive for a student seeing it for the first time. If the source provides an example, reproduce it faithfully and label it "Source example:". If the source provides enough stated facts to derive one, construct it and label it "Derived from source:". If neither is possible, write "Insufficient detail in source for a worked example."

## 5. Critical Analysis
Limitations, failure modes, open questions, or trade-offs that the source explicitly acknowledges. For each, state what the source says and what it leaves unanswered. Label any gap with [not addressed in source]. Frame entries as the question a skeptical peer reviewer would raise, followed by what the source answers.

## 6. Prerequisites & Related Work
Background knowledge the presenter explicitly assumes the audience has. Papers, systems, datasets, frameworks, or concepts explicitly referenced or built upon. If the source references nothing external, write "None explicitly stated in source."

## 7. Practitioner Takeaways
Five to seven concise, action-oriented bullets. What should an engineer or researcher do, build, or think differently after internalizing this material? Ground each bullet in a specific claim or result from the source.

STRICT RULES — these override everything else:
- Assert ONLY facts explicitly stated in the source video. Never speculate, fill gaps, or draw on background knowledge not present in the video.
- If the source is ambiguous or incomplete on a point, write [source unclear] inline rather than inferring an answer.
- Define every acronym on first use: write the expansion in parentheses the first time, e.g. GAN (Generative Adversarial Network).
- Bold (**term**) every key technical term on its first appearance only; do not re-bold on later uses.
- Use the ## and ### headers exactly as shown — do not add, remove, reorder, or rename them.
- The YAML frontmatter must be syntactically valid: no trailing spaces, no unquoted colons, no extra indentation, array values in bracket notation.
- Write in precise academic English. No colloquialisms, filler phrases, or hedging language unless quoting the source.
PROMPT
)

    nlm report create "$NB_ID" \
        --format "Create Your Own" \
        --prompt "$REPORT_PROMPT" \
        --confirm >>"$OPS_LOG" 2>&1

    log "Report generation queued."
fi

# ── Generate infographic ──────────────────────────────────────────────────────
if [ "$INF_ENABLED" = "true" ]; then
    log "Requesting infographic (${INF_ORIENTATION} / ${INF_DETAIL} / ${INF_STYLE})..."
    nlm infographic create "$NB_ID" \
        --orientation "$INF_ORIENTATION" \
        --detail "$INF_DETAIL" \
        --style "$INF_STYLE" \
        --focus "$INF_FOCUS" \
        --confirm >>"$OPS_LOG" 2>&1
    log "Infographic generation queued."
fi

# ── Poll until artifacts complete ─────────────────────────────────────────────
# python3 - <<'HEREDOC' inside a pipeline clobbers stdin (heredoc wins over pipe),
# so the script is stored in a variable and passed via -c instead.
_ARTIFACT_STATUS_PY=$(cat <<'PYEOF'
import json, sys

target = sys.argv[1].lower()
try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else \
            data.get('artifacts', data.get('items', data.get('outputs', [])))
    for item in items:
        t = str(item.get('type') or item.get('artifact_type') or '').lower()
        if t == target:
            raw = str(item.get('status') or item.get('state') or 'unknown').lower()
            if raw in ('complete', 'done', 'success', 'finished', 'ready'):
                raw = 'completed'
            print(raw)
            sys.exit(0)
    print('pending')
except Exception as exc:
    sys.stderr.write('status-parse error: {}\n'.format(exc))
    print('unknown')
PYEOF
)

# Returns: completed | in_progress | failed | pending | unknown
check_artifact_status() {
    local artifact_type="$1" status probe
    status=$(nlm studio status "$NB_ID" --json 2>>"$OPS_LOG" \
        | python3 -c "$_ARTIFACT_STATUS_PY" "$artifact_type" \
        || echo 'unknown')
    # nlm 0.15.4 reports finished "Create Your Own" reports as status "unknown"
    # forever. A successful, non-empty download proves the artifact is done.
    if [ "$status" = "unknown" ]; then
        probe=$(mktemp)
        if nlm download "$artifact_type" "$NB_ID" --output "$probe" >/dev/null 2>&1 \
           && [ -s "$probe" ]; then
            status="completed"
        fi
        rm -f "$probe"
    fi
    echo "$status"
}

log "Polling every ${POLL_INTERVAL}s (max $((POLL_MAX * POLL_INTERVAL))s)..."
attempt=0
while true; do
    attempt=$((attempt + 1))

    REPORT_STATUS="completed"   # default: treat as done when disabled
    INF_STATUS="completed"

    [ "$REPORT_ENABLED" = "true" ] && REPORT_STATUS=$(check_artifact_status "report")
    [ "$INF_ENABLED"    = "true" ] && INF_STATUS=$(check_artifact_status "infographic")

    log "Poll $attempt/$POLL_MAX — report: $REPORT_STATUS | infographic: $INF_STATUS"

    if [ "$REPORT_STATUS" = "failed" ] || [ "$INF_STATUS" = "failed" ]; then
        log "ERROR: an artifact generation failed. See $OPS_LOG for details."
        exit 1
    fi

    if [ "$REPORT_STATUS" = "completed" ] && [ "$INF_STATUS" = "completed" ]; then
        log "All artifacts ready."
        break
    fi

    if [ "$attempt" -ge "$POLL_MAX" ]; then
        log "ERROR: timed out after $((POLL_MAX * POLL_INTERVAL))s. Artifacts may still be generating."
        log "Check the notebook manually: nlm studio status $NB_ID"
        exit 1
    fi

    sleep "$POLL_INTERVAL"
done

# ── Download artifacts ────────────────────────────────────────────────────────
if [ "$REPORT_ENABLED" = "true" ]; then
    REPORT_FILE="${OUT_DIR}/summary.md"
    log "Downloading report -> $REPORT_FILE"
    nlm download report "$NB_ID" --output "$REPORT_FILE" >>"$OPS_LOG" 2>&1
    log "Report saved."
fi

if [ "$INF_ENABLED" = "true" ]; then
    INF_FILE="${OUT_DIR}/infographic.png"
    log "Downloading infographic -> $INF_FILE"
    nlm download infographic "$NB_ID" --output "$INF_FILE" >>"$OPS_LOG" 2>&1
    log "Infographic saved."
fi

# ── Write manifest ────────────────────────────────────────────────────────────
export YT_TITLE YT_TIMESTAMP URL NB_ID OUT_DIR REPORT_ENABLED INF_ENABLED
python3 - <<'PYEOF'
import json, os

artifacts = {}
if os.environ.get("REPORT_ENABLED") == "true":
    artifacts["report"] = "summary.md"
if os.environ.get("INF_ENABLED") == "true":
    artifacts["infographic"] = "infographic.png"

manifest = {
    "title":       os.environ["YT_TITLE"],
    "url":         os.environ["URL"],
    "timestamp":   os.environ["YT_TIMESTAMP"],
    "notebook_id": os.environ["NB_ID"],
    "output_dir":  os.environ["OUT_DIR"],
    "artifacts":   artifacts,
}

manifest_path = os.path.join(os.environ["OUT_DIR"], "manifest.json")
with open(manifest_path, "w") as fh:
    json.dump(manifest, fh, indent=2)
PYEOF
log "Manifest -> ${OUT_DIR}/manifest.json"

# ── Cleanup ───────────────────────────────────────────────────────────────────
if [ "$DELETE_NB" = "true" ]; then
    log "Deleting notebook $NB_ID from NotebookLM..."
    nlm notebook delete "$NB_ID" --confirm >>"$OPS_LOG" 2>&1
    log "Notebook deleted."
else
    log "Notebook $NB_ID retained in NotebookLM (set delete_notebook_after_download=true in pipeline_config.json to auto-delete)."
fi

log "=================================================================="
log "NLM PIPELINE COMPLETE"
log "Output folder : $OUT_DIR"
log "Ops log       : $OPS_LOG"
log "=================================================================="
notify "YT Ingest: summary ready" "${YT_TITLE:-$URL}"
