#!/bin/bash
# composite_bezel — composite a screen recording (with iPad bezel) over real-life background footage
# The bezel floats transparently over the background; no solid color box around it.
# Usage: composite_bezel [OPTIONS] background.mp4 screen.mp4 [output.mp4]
#        composite_bezel update
#
# Overlay options:
#   --overlay-scale 0.7   iPad height as fraction of background height (default: 0.7)
#   --x N                 X pixel position of overlay (default: right side minus --margin)
#   --y N                 Y pixel position of overlay (default: vertically centered)
#   --margin 40           right/left edge gap when --x is not set (default: 40)
#
# Timing options:
#   --bg-start N          start time in seconds for background clip (default: 0)
#   --scr-start N         start time in seconds for screen recording (default: 0)
#   --duration N          render N seconds of output (default: min of remaining clip lengths)
#   --test-seconds N      alias for --duration
#   --audio both|bg|screen|none  which audio to include (default: both)

set -e

# Resolve real script location through symlinks (BASH_SOURCE[0] may be a symlink in homebrew/bin)
SCRIPT_DIR="$(cd "$(dirname "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")" && pwd)"
BEZEL="$SCRIPT_DIR/iPad mini - Starlight - Portrait.png"

GITHUB_RAW_BASE="https://raw.githubusercontent.com/robert-friedland/se-video-tools/main"

# Update subcommand
if [ "$1" = "update" ]; then
    echo "Updating composite_bezel..."
    curl -fsSL "${GITHUB_RAW_BASE}/composite_bezel.sh" -o "$SCRIPT_DIR/composite_bezel.sh.tmp" \
        && mv "$SCRIPT_DIR/composite_bezel.sh.tmp" "$SCRIPT_DIR/composite_bezel.sh" \
        && chmod +x "$SCRIPT_DIR/composite_bezel.sh"
    curl -fsSL "${GITHUB_RAW_BASE}/iPad%20mini%20-%20Starlight%20-%20Portrait.png" \
        -o "$SCRIPT_DIR/iPad mini - Starlight - Portrait.png"
    if [ -d "$HOME/.claude/commands" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/commands/composite-bezel.md" \
            -o "$HOME/.claude/commands/composite-bezel.md"
        echo "Claude skill updated."
    fi
    echo "Done."
    exit 0
fi

# Defaults
OVERLAY_SCALE=0.7
MARGIN=40
OVL_X_OVERRIDE=""
OVL_Y_OVERRIDE=""
BG_START=0
SCR_START=0
DURATION_OVERRIDE=""
AUDIO_MODE="both"  # both | bg | screen | none

# Parse args — flags may appear anywhere (before or after positionals)
POSITIONALS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --overlay-scale) OVERLAY_SCALE="$2"; shift 2 ;;
        --margin)        MARGIN="$2";        shift 2 ;;
        --x)             OVL_X_OVERRIDE="$2"; shift 2 ;;
        --y)             OVL_Y_OVERRIDE="$2"; shift 2 ;;
        --bg-start)      BG_START="$2";      shift 2 ;;
        --scr-start)     SCR_START="$2";     shift 2 ;;
        --duration|--test-seconds) DURATION_OVERRIDE="$2"; shift 2 ;;
        --audio)         AUDIO_MODE="$2";    shift 2 ;;
        --*)
            echo "Unknown option: $1"
            echo "Usage: $0 [--overlay-scale 0.7] [--x N] [--y N] [--margin 40] [--bg-start N] [--scr-start N] [--duration N] background.mp4 screen.mp4 [output.mp4]"
            exit 1 ;;
        *) POSITIONALS+=("$1"); shift ;;
    esac
done

BG="${POSITIONALS[0]:-}"
SCR="${POSITIONALS[1]:-}"
OUTPUT="${POSITIONALS[2]:-${POSITIONALS[0]%.*}_composite.mp4}"

if [ -z "$BG" ] || [ -z "$SCR" ]; then
    echo "Usage: $0 [--overlay-scale 0.7] [--margin 40] [--test-seconds N] background.mp4 screen.mp4 [output.mp4]"
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

# Bezel canvas dimensions (1780x2550)
BEZEL_W=1780
BEZEL_H=2550

# Scale factor: screen content occupies 89% of the bezel canvas (matches ipad_bezel.sh / Resolve workflow)
SCALE=0.89

IPAD_RATIO=0.6567
RATIO_TOLERANCE=0.05

# ── Probe background video ────────────────────────────────────────────────────
read -r BG_W BG_H BG_BITRATE BG_ROTATION < <(python3 - "$BG" <<'PYEOF'
import sys, json, subprocess

result = subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0",
     "-show_entries", "stream=width,height,bit_rate:stream_side_data=rotation",
     "-print_format", "json", sys.argv[1]],
    capture_output=True, text=True
)
d = json.loads(result.stdout)["streams"][0]
w = d["width"]
h = d["height"]
bitrate = d.get("bit_rate", "")
rotation = 0
for sd in d.get("side_data_list", []):
    if "rotation" in sd:
        rotation = int(sd["rotation"])
        break
print(w, h, bitrate, rotation)
PYEOF
)

# Fall back to container bitrate if stream bitrate unavailable
if [ -z "$BG_BITRATE" ] || [ "$BG_BITRATE" = "N/A" ]; then
    BG_BITRATE=$(ffprobe -v error -show_entries format=bit_rate \
        -of csv=p=0 "$BG" 2>/dev/null)
fi
# Last-resort floor
if [ -z "$BG_BITRATE" ] || [ "$BG_BITRATE" = "N/A" ]; then
    BG_BITRATE=10000000
fi

# Rotation-adjusted effective dimensions for background
if [ "$BG_ROTATION" = "-90" ] || [ "$BG_ROTATION" = "90" ] || \
   [ "$BG_ROTATION" = "270" ] || [ "$BG_ROTATION" = "-270" ]; then
    BG_EFF_W=$BG_H
    BG_EFF_H=$BG_W
else
    BG_EFF_W=$BG_W
    BG_EFF_H=$BG_H
fi

# Warn if background is not landscape
BG_IS_LANDSCAPE=$(python3 -c "print('true' if $BG_EFF_W > $BG_EFF_H else 'false')")
if [ "$BG_IS_LANDSCAPE" = "false" ]; then
    echo "Warning: background effective dimensions ${BG_EFF_W}x${BG_EFF_H} are portrait, not landscape."
    echo "  The bezel overlay may have negative coordinates and appear partially clipped off-screen."
    read -p "Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi

# ── Probe screen recording ────────────────────────────────────────────────────
read -r SCR_W SCR_H SCR_BITRATE SCR_ROTATION < <(python3 - "$SCR" <<'PYEOF'
import sys, json, subprocess

result = subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0",
     "-show_entries", "stream=width,height,bit_rate:stream_side_data=rotation",
     "-print_format", "json", sys.argv[1]],
    capture_output=True, text=True
)
d = json.loads(result.stdout)["streams"][0]
w = d["width"]
h = d["height"]
bitrate = d.get("bit_rate", "")
rotation = 0
for sd in d.get("side_data_list", []):
    if "rotation" in sd:
        rotation = int(sd["rotation"])
        break
print(w, h, bitrate, rotation)
PYEOF
)

# Rotation-adjusted effective dimensions for screen recording
if [ "$SCR_ROTATION" = "-90" ] || [ "$SCR_ROTATION" = "90" ] || \
   [ "$SCR_ROTATION" = "270" ] || [ "$SCR_ROTATION" = "-270" ]; then
    SCR_EFF_W=$SCR_H
    SCR_EFF_H=$SCR_W
else
    SCR_EFF_W=$SCR_W
    SCR_EFF_H=$SCR_H
fi

# Validate screen recording aspect ratio (iPad mini portrait ~0.6567)
VALID_RATIO=$(python3 -c "
ratio = $SCR_EFF_W / $SCR_EFF_H
expected = $IPAD_RATIO
diff = abs(ratio - expected) / expected
print('true' if diff <= $RATIO_TOLERANCE else 'false')
")

if [ "$VALID_RATIO" = "false" ]; then
    echo "Warning: screen recording effective dimensions ${SCR_EFF_W}x${SCR_EFF_H} (ratio $(python3 -c "print(round($SCR_EFF_W/$SCR_EFF_H,3))")) don't match iPad mini portrait (expected ~${IPAD_RATIO} ±${RATIO_TOLERANCE})"
    read -p "Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi

# ── Calculate dimensions ──────────────────────────────────────────────────────

# Screen area within bezel canvas (89% of bezel, even integers)
SCREEN_W=$(python3 -c "print(round($BEZEL_W * $SCALE / 2) * 2)")
SCREEN_H=$(python3 -c "print(round($BEZEL_H * $SCALE / 2) * 2)")
X_OFF=$(( (BEZEL_W - SCREEN_W) / 2 ))
Y_OFF=$(( (BEZEL_H - SCREEN_H) / 2 ))

# Overlay dimensions (scaled bezel, even integers)
OVL_H=$(python3 -c "print(round($BG_EFF_H * $OVERLAY_SCALE / 2) * 2)")
OVL_W=$(python3 -c "print(round($OVL_H * $BEZEL_W / $BEZEL_H / 2) * 2)")

# Position: use explicit --x/--y if provided, otherwise default (right side, vertically centered)
if [ -n "$OVL_X_OVERRIDE" ]; then
    OVL_X="$OVL_X_OVERRIDE"
else
    OVL_X=$(( BG_EFF_W - OVL_W - MARGIN ))
fi
if [ -n "$OVL_Y_OVERRIDE" ]; then
    OVL_Y="$OVL_Y_OVERRIDE"
else
    OVL_Y=$(( (BG_EFF_H - OVL_H) / 2 ))
fi

# Output bitrate: 75% of background (higher than ipad_bezel.sh's 60% — two motion sources)
OUTPUT_BITRATE=$(python3 -c "print(int(float('$BG_BITRATE') * 0.75))")

# ── Durations ─────────────────────────────────────────────────────────────────
BG_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$BG" 2>/dev/null)
SCR_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SCR" 2>/dev/null)

# Active duration = min of remaining clip lengths after applying start offsets
ACTIVE_DURATION=$(python3 -c "
bg_rem  = float('$BG_DURATION')  - float('$BG_START')
scr_rem = float('$SCR_DURATION') - float('$SCR_START')
print(min(bg_rem, scr_rem))
")

if [ -n "$DURATION_OVERRIDE" ]; then
    ACTIVE_DURATION="$DURATION_OVERRIDE"
fi

# ── Audio detection ───────────────────────────────────────────────────────────
BG_HAS_AUDIO=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_type -of csv=p=0 "$BG" 2>/dev/null)
SCR_HAS_AUDIO=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_type -of csv=p=0 "$SCR" 2>/dev/null)

# ── Summary ───────────────────────────────────────────────────────────────────
echo "Background:      ${BG_EFF_W}x${BG_EFF_H} (encoded ${BG_W}x${BG_H}, rotation ${BG_ROTATION}°) — ${BG_DURATION}s @ ${BG_BITRATE}bps"
echo "Screen recording:${SCR_EFF_W}x${SCR_EFF_H} (encoded ${SCR_W}x${SCR_H}, rotation ${SCR_ROTATION}°) — ${SCR_DURATION}s"
echo "Sync:            bg starts at ${BG_START}s, screen starts at ${SCR_START}s"
echo "Active duration: ${ACTIVE_DURATION}s$([ -n "$DURATION_OVERRIDE" ] && echo " (--duration)")"
echo "Bezel canvas:    ${BEZEL_W}x${BEZEL_H} → screen area ${SCREEN_W}x${SCREEN_H} at offset ${X_OFF},${Y_OFF}"
echo "Overlay size:    ${OVL_W}x${OVL_H} at position ${OVL_X},${OVL_Y} (scale=${OVERLAY_SCALE})"
echo "Output bitrate:  ${OUTPUT_BITRATE}bps"
echo "Output:          $OUTPUT"
echo ""

# ── Parallel chunk processing ─────────────────────────────────────────────────
N_JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
N_JOBS=$(python3 -c "print(max(1, min($N_JOBS, int(float('$ACTIVE_DURATION')))))")
CHUNK_DUR=$(python3 -c "print(float('$ACTIVE_DURATION') / $N_JOBS)")

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

echo "Processing ${N_JOBS} chunks in parallel..."

PIDS=()
for i in $(seq 0 $((N_JOBS - 1))); do
    # Each clip is trimmed independently using its own start offset
    CHUNK_OFFSET=$(python3 -c "print($i * $CHUNK_DUR)")
    CHUNK_LEN=$(python3 -c "print(min(($i + 1) * $CHUNK_DUR, float('$ACTIVE_DURATION')) - $i * $CHUNK_DUR)")

    BG_START_I=$(python3 -c "print(float('$BG_START') + $CHUNK_OFFSET)")
    BG_END_I=$(python3 -c "print(float('$BG_START') + $CHUNK_OFFSET + $CHUNK_LEN)")
    SCR_START_I=$(python3 -c "print(float('$SCR_START') + $CHUNK_OFFSET)")
    SCR_END_I=$(python3 -c "print(float('$SCR_START') + $CHUNK_OFFSET + $CHUNK_LEN)")

    CHUNK_OUT="$WORK_DIR/chunk_$(printf '%04d' $i).mp4"

    # Video filter: single-pass composite with transparency
    # Critical chain: format=rgba before transparent pad → format=auto on both overlays
    VIDEO_FILTER="\
[0:v]trim=${BG_START_I}:${BG_END_I},setpts=PTS-STARTPTS[bg];\
[1:v]trim=${SCR_START_I}:${SCR_END_I},setpts=PTS-STARTPTS,\
scale=${SCREEN_W}:${SCREEN_H}:force_original_aspect_ratio=decrease,\
pad=${SCREEN_W}:${SCREEN_H}:(ow-iw)/2:(oh-ih)/2:black,\
format=rgba[footage];\
[footage]pad=${BEZEL_W}:${BEZEL_H}:${X_OFF}:${Y_OFF}:color=black@0[canvas];\
[canvas][2:v]overlay=0:0:format=auto[bezeled];\
[bezeled]scale=${OVL_W}:${OVL_H}[scaled];\
[bg][scaled]overlay=${OVL_X}:${OVL_Y}:format=auto[out]"

    case "$AUDIO_MODE" in
        both)
            if [ "$BG_HAS_AUDIO" = "audio" ] && [ "$SCR_HAS_AUDIO" = "audio" ]; then
                # Mix both — normalize=0 prevents amix from halving each channel's volume
                FILTER="${VIDEO_FILTER};\
[0:a]atrim=${BG_START_I}:${BG_END_I},asetpts=PTS-STARTPTS[abg];\
[1:a]atrim=${SCR_START_I}:${SCR_END_I},asetpts=PTS-STARTPTS[ascr];\
[abg][ascr]amix=inputs=2:duration=shortest:normalize=0[aout]"
                AUDIO_ARGS=(-map "[aout]" -c:a aac -b:a 192k)
            elif [ "$BG_HAS_AUDIO" = "audio" ]; then
                FILTER="${VIDEO_FILTER};[0:a]atrim=${BG_START_I}:${BG_END_I},asetpts=PTS-STARTPTS[aout]"
                AUDIO_ARGS=(-map "[aout]" -c:a aac -b:a 128k)
            elif [ "$SCR_HAS_AUDIO" = "audio" ]; then
                FILTER="${VIDEO_FILTER};[1:a]atrim=${SCR_START_I}:${SCR_END_I},asetpts=PTS-STARTPTS[aout]"
                AUDIO_ARGS=(-map "[aout]" -c:a aac -b:a 128k)
            else
                FILTER="$VIDEO_FILTER"; AUDIO_ARGS=()
            fi ;;
        bg)
            if [ "$BG_HAS_AUDIO" = "audio" ]; then
                FILTER="${VIDEO_FILTER};[0:a]atrim=${BG_START_I}:${BG_END_I},asetpts=PTS-STARTPTS[aout]"
                AUDIO_ARGS=(-map "[aout]" -c:a aac -b:a 128k)
            else
                echo "Warning: --audio bg requested but background has no audio stream. No audio in output."
                FILTER="$VIDEO_FILTER"; AUDIO_ARGS=()
            fi ;;
        screen)
            if [ "$SCR_HAS_AUDIO" = "audio" ]; then
                FILTER="${VIDEO_FILTER};[1:a]atrim=${SCR_START_I}:${SCR_END_I},asetpts=PTS-STARTPTS[aout]"
                AUDIO_ARGS=(-map "[aout]" -c:a aac -b:a 128k)
            else
                echo "Warning: --audio screen requested but screen recording has no audio stream. No audio in output."
                FILTER="$VIDEO_FILTER"; AUDIO_ARGS=()
            fi ;;
        none)
            FILTER="$VIDEO_FILTER"; AUDIO_ARGS=() ;;
        *)
            echo "Error: --audio must be one of: both, bg, screen, none"
            exit 1 ;;
    esac

    ffmpeg \
        -i "$BG" -i "$SCR" -i "$BEZEL" \
        -filter_complex "$FILTER" \
        -map "[out]" "${AUDIO_ARGS[@]}" \
        -c:v hevc_videotoolbox -b:v "${OUTPUT_BITRATE}" -tag:v hvc1 \
        -y "$CHUNK_OUT" \
        > "$WORK_DIR/chunk_${i}.log" 2>&1 &
    PIDS+=($!)
done

FAILED=false
for i in "${!PIDS[@]}"; do
    if wait "${PIDS[$i]}"; then
        echo "  Chunk $((i+1))/${N_JOBS} done"
    else
        echo "  Chunk $((i+1))/${N_JOBS} FAILED — see $WORK_DIR/chunk_${i}.log"
        FAILED=true
    fi
done

$FAILED && exit 1

# ── Merge chunks ──────────────────────────────────────────────────────────────
echo ""
echo "Merging ${N_JOBS} chunks..."
printf "file '%s'\n" "$WORK_DIR"/chunk_????.mp4 > "$WORK_DIR/concat.txt"
ffmpeg -f concat -safe 0 -i "$WORK_DIR/concat.txt" -c copy -y "$OUTPUT" 2>/dev/null

# ── Verify output duration ────────────────────────────────────────────────────
OUTPUT_DURATION=$(ffprobe -v error -show_entries format=duration \
    -of csv=p=0 "$OUTPUT" 2>/dev/null)
DURATION_OK=$(python3 -c "print('true' if abs(float('$OUTPUT_DURATION') - float('$ACTIVE_DURATION')) < 1.0 else 'false')")

if [ "$DURATION_OK" = "false" ]; then
    echo ""
    echo "ERROR: output duration (${OUTPUT_DURATION}s) doesn't match expected (${ACTIVE_DURATION}s)"
    echo "The composite file may have errors. Check logs in: $WORK_DIR"
    exit 1
fi

echo ""
echo "Done: $OUTPUT (${OUTPUT_DURATION}s)"
