#!/bin/bash
# sync_clap — detect a sync clap in two video files and output --bg-start / --scr-start offsets
#             for use with composite_bezel.
#
# Usage: sync_clap [OPTIONS] background.mp4 screen.mp4
#        sync_clap update
#
# Options:
#   --search-start N   start of search window in both clips (default: 0)
#   --search-end N     end of search window in both clips (default: 30)
#
# Output:
#   Background clap:  2.314s  (searched 0.0–30.0s)
#   Screen clap:      0.892s  (searched 0.0–30.0s)
#   SYNC bg=2.314 scr=0.892
#
#   Suggested command:
#     composite_bezel --bg-start 2.314 --scr-start 0.892 "bg.mp4" "screen.mp4"
#
# Known limitations:
#   - Both clips must have audio (no single-clip mode in v1)
#   - Both clips share one search window; use --search-start/--search-end to narrow it
#     if there is pre-roll noise before the clap (per-clip windows planned for v2)
#   - A loud sound before the clap within the search window can produce a false positive

set -e

# Resolve real script location through symlinks (handles Homebrew symlinks)
SCRIPT_DIR="$(cd "$(dirname "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")" && pwd)"

GITHUB_RAW_BASE="https://raw.githubusercontent.com/robert-friedland/se-video-tools/main"

# ── Update subcommand ─────────────────────────────────────────────────────────
if [ "$1" = "update" ]; then
    echo "Updating sync_clap..."
    curl -fsSL "${GITHUB_RAW_BASE}/sync_clap.sh" -o "$SCRIPT_DIR/sync_clap.sh.tmp" \
        && mv "$SCRIPT_DIR/sync_clap.sh.tmp" "$SCRIPT_DIR/sync_clap.sh" \
        && chmod +x "$SCRIPT_DIR/sync_clap.sh"
    if [ -d "$HOME/.claude/commands" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/commands/sync-clap.md" \
            -o "$HOME/.claude/commands/sync-clap.md"
        echo "Claude skill updated."
    fi
    echo "Done."
    exit 0
fi

# ── Check dependencies ────────────────────────────────────────────────────────
if ! command -v ffmpeg &>/dev/null; then
    echo "Error: ffmpeg is not installed. Run: brew install ffmpeg"
    exit 1
fi

# ── Defaults ──────────────────────────────────────────────────────────────────
SEARCH_START=0
SEARCH_END=30
USE_TIMESTAMP=false

# ── Parse args ────────────────────────────────────────────────────────────────
POSITIONALS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --search-start) SEARCH_START="$2"; shift 2 ;;
        --search-end)   SEARCH_END="$2";   shift 2 ;;
        --timestamp)    USE_TIMESTAMP=true; shift ;;
        --*)
            echo "Unknown option: $1"
            echo "Usage: $0 [--search-start N] [--search-end N] [--timestamp] background.mp4 screen.mp4"
            exit 1 ;;
        *) POSITIONALS+=("$1"); shift ;;
    esac
done

BG="${POSITIONALS[0]:-}"
SCR="${POSITIONALS[1]:-}"

if [ -z "$BG" ] || [ -z "$SCR" ]; then
    echo "Usage: $0 [--search-start N] [--search-end N] [--timestamp] background.mp4 screen.mp4"
    exit 1
fi

if [ ! -f "$BG" ]; then
    echo "Error: background file not found: $BG"
    exit 1
fi

if [ ! -f "$SCR" ]; then
    echo "Error: screen recording not found: $SCR"
    exit 1
fi

# ── Timestamp sync mode ───────────────────────────────────────────────────────
if $USE_TIMESTAMP; then
    BG_CTIME=$(ffprobe -v error -show_entries format_tags=creation_time \
        -of csv=p=0 "$BG" 2>/dev/null | head -1)
    SCR_CTIME=$(ffprobe -v error -show_entries format_tags=creation_time \
        -of csv=p=0 "$SCR" 2>/dev/null | head -1)

    if [ -z "$BG_CTIME" ]; then
        echo "Error: background clip has no creation_time metadata: $BG"
        exit 1
    fi
    if [ -z "$SCR_CTIME" ]; then
        echo "Error: screen recording has no creation_time metadata: $SCR"
        exit 1
    fi

    RESULT=$(python3 - "$BG_CTIME" "$SCR_CTIME" <<'PYEOF'
import sys
from datetime import datetime
def parse_ts(s):
    return datetime.fromisoformat(s.strip().replace('Z', '+00:00'))
bg_t = parse_ts(sys.argv[1])
scr_t = parse_ts(sys.argv[2])
offset = (scr_t - bg_t).total_seconds()
if offset >= 0:
    print(f"BG_TIME {offset:.3f}")
    print("SCR_TIME 0.000")
else:
    print("BG_TIME 0.000")
    print(f"SCR_TIME {-offset:.3f}")
PYEOF
    )

    BG_TIME=$(echo "$RESULT" | awk '/^BG_TIME/  {print $2}')
    SCR_TIME=$(echo "$RESULT" | awk '/^SCR_TIME/ {print $2}')

    echo "Background timestamp: $BG_CTIME"
    echo "Screen timestamp:     $SCR_CTIME"
    echo "Note: timestamp precision is typically 1 second; result may be off by ±1s"
    echo ""
    echo "SYNC bg=${BG_TIME} scr=${SCR_TIME}"
    echo ""
    echo "Suggested command:"
    echo "  composite_bezel --bg-start ${BG_TIME} --scr-start ${SCR_TIME} \"${BG}\" \"${SCR}\""
    exit 0
fi

# ── Validate audio streams ────────────────────────────────────────────────────
BG_HAS_AUDIO=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_type -of csv=p=0 "$BG" 2>/dev/null)
SCR_HAS_AUDIO=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_type -of csv=p=0 "$SCR" 2>/dev/null)

if [ "$BG_HAS_AUDIO" != "audio" ]; then
    echo "Error: background clip has no audio stream: $BG"
    exit 1
fi
if [ "$SCR_HAS_AUDIO" != "audio" ]; then
    echo "Error: screen recording has no audio stream: $SCR"
    exit 1
fi

# ── Validate search_start vs clip durations ───────────────────────────────────
BG_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$BG" 2>/dev/null)
SCR_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SCR" 2>/dev/null)

python3 - "$BG_DURATION" "$SCR_DURATION" "$SEARCH_START" <<'PYEOF'
import sys
bg_dur, scr_dur, s_start = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
if s_start >= bg_dur:
    print(f"Error: --search-start {s_start} exceeds background duration {bg_dur:.1f}s")
    sys.exit(1)
if s_start >= scr_dur:
    print(f"Error: --search-start {s_start} exceeds screen recording duration {scr_dur:.1f}s")
    sys.exit(1)
PYEOF

SEARCH_DUR=$(python3 -c "print(float('$SEARCH_END') - float('$SEARCH_START'))")

# ── Work directory ────────────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

# ── Extract audio ─────────────────────────────────────────────────────────────
# -ss after -i = exact (sample-accurate) seek
# -t = duration from seek point; ffmpeg stops at EOF if clip is shorter
echo "Extracting audio from background..."
ffmpeg -i "$BG" -ss "$SEARCH_START" -t "$SEARCH_DUR" \
    -ac 1 -ar 8000 -f s16le "$WORK_DIR/audio_bg.raw" -y 2>/dev/null

echo "Extracting audio from screen recording..."
ffmpeg -i "$SCR" -ss "$SEARCH_START" -t "$SEARCH_DUR" \
    -ac 1 -ar 8000 -f s16le "$WORK_DIR/audio_scr.raw" -y 2>/dev/null

# ── Onset detection ───────────────────────────────────────────────────────────
# Returns lines: "TIME <seconds>", "ACTUAL_DUR <seconds>", optionally "WARN: <message>"
# Exits 0 on success or WARN (non-fatal); exits 1 on hard error.
detect_onset() {
    local raw_file="$1"
    local search_start="$2"
    python3 - "$raw_file" "$search_start" <<'PYEOF'
import sys, array, math

raw_file = sys.argv[1]
search_start = float(sys.argv[2])
SAMPLE_RATE = 8000
WINDOW = 40   # 5ms at 8kHz
HOP    = 20   # 2.5ms hop

raw = open(raw_file, 'rb').read()
if not raw:
    print("ERROR: empty audio buffer")
    sys.exit(1)

actual_dur = len(raw) / (SAMPLE_RATE * 2)
print(f"ACTUAL_DUR {actual_dur:.3f}")

samples = array.array('h', raw)

# Windowed RMS energy
energy = []
for i in range(0, len(samples) - WINDOW, HOP):
    chunk = samples[i:i+WINDOW]
    energy.append(math.sqrt(sum(x * x for x in chunk) / WINDOW))

if not energy:
    print("ERROR: audio segment too short for onset detection")
    sys.exit(1)

max_energy = max(energy)

# Positive-only energy delta
delta = [max(0.0, energy[i] - energy[i-1]) for i in range(1, len(energy))]

if not delta:
    print("ERROR: audio segment too short for onset detection")
    sys.exit(1)

peak_delta = max(delta)
peak_idx = delta.index(peak_delta)

# SNR check: peak energy rise must be at least 10% of peak energy
# (fires on silence, constant hum, or any audio with no sharp transient)
if peak_delta < 0.1 * max_energy:
    print(f"WARN: no clear transient detected — peak rise {peak_delta:.1f} is only "
          f"{100*peak_delta/max_energy:.1f}% of peak energy {max_energy:.1f}. "
          f"Check that the search window contains the clap.")
    pipe_time = peak_idx * HOP / SAMPLE_RATE
    print(f"TIME {search_start + pipe_time:.3f}")
    sys.exit(0)  # non-fatal: let caller decide

# Walk backward from peak to find start of the rising edge
threshold = 0.5 * peak_delta
onset_idx = peak_idx
for j in range(peak_idx, -1, -1):
    if delta[j] >= threshold:
        onset_idx = j
    else:
        break

pipe_time = onset_idx * HOP / SAMPLE_RATE
print(f"TIME {search_start + pipe_time:.3f}")
sys.exit(0)
PYEOF
}

BG_RESULT=$(detect_onset "$WORK_DIR/audio_bg.raw" "$SEARCH_START")
BG_EXIT=$?
if [ $BG_EXIT -ne 0 ]; then
    echo "Error: onset detection failed for background:"
    echo "$BG_RESULT"
    exit 1
fi

SCR_RESULT=$(detect_onset "$WORK_DIR/audio_scr.raw" "$SEARCH_START")
SCR_EXIT=$?
if [ $SCR_EXIT -ne 0 ]; then
    echo "Error: onset detection failed for screen recording:"
    echo "$SCR_RESULT"
    exit 1
fi

# ── Parse results ─────────────────────────────────────────────────────────────
BG_TIME=$(echo "$BG_RESULT"    | awk '/^TIME/     {print $2}')
BG_DUR=$(echo "$BG_RESULT"     | awk '/^ACTUAL_DUR/ {print $2}')
BG_WARN=$(echo "$BG_RESULT"    | grep '^WARN:' || true)

SCR_TIME=$(echo "$SCR_RESULT"  | awk '/^TIME/     {print $2}')
SCR_DUR=$(echo "$SCR_RESULT"   | awk '/^ACTUAL_DUR/ {print $2}')
SCR_WARN=$(echo "$SCR_RESULT"  | grep '^WARN:' || true)

# Actual searched window end (clip may have ended before SEARCH_END)
BG_SEARCHED_END=$(python3 -c "print(round(float('$SEARCH_START') + float('$BG_DUR'), 1))")
SCR_SEARCHED_END=$(python3 -c "print(round(float('$SEARCH_START') + float('$SCR_DUR'), 1))")

# ── Surface warnings ──────────────────────────────────────────────────────────
if [ -n "$BG_WARN" ]; then
    echo "Warning (background): $BG_WARN"
fi
if [ -n "$SCR_WARN" ]; then
    echo "Warning (screen):     $SCR_WARN"
fi
if [ -n "$BG_WARN" ] || [ -n "$SCR_WARN" ]; then
    echo ""
    echo "Results may be inaccurate. Narrow the search window with --search-start / --search-end"
    echo "to isolate the clap, then re-run."
    echo ""
fi

# ── Report ────────────────────────────────────────────────────────────────────
BG_NOTE=""
SCR_NOTE=""
[ "$(python3 -c "print('y' if $BG_SEARCHED_END < $SEARCH_END - 0.5 else '')")" = "y" ] && \
    BG_NOTE=", clip ended early"
[ "$(python3 -c "print('y' if $SCR_SEARCHED_END < $SEARCH_END - 0.5 else '')")" = "y" ] && \
    SCR_NOTE=", clip ended early"

echo "Background clap:  ${BG_TIME}s  (searched ${SEARCH_START}–${BG_SEARCHED_END}s${BG_NOTE})"
echo "Screen clap:      ${SCR_TIME}s  (searched ${SEARCH_START}–${SCR_SEARCHED_END}s${SCR_NOTE})"
echo "SYNC bg=${BG_TIME} scr=${SCR_TIME}"
echo ""
echo "Suggested command:"
echo "  composite_bezel --bg-start ${BG_TIME} --scr-start ${SCR_TIME} \"${BG}\" \"${SCR}\""
