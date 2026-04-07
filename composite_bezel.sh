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
#   --output-width N      scale output to this width, e.g. 1920 for 1080p (default: native)

set -e

# Resolve real script location through symlinks (BASH_SOURCE[0] may be a symlink in homebrew/bin)
SCRIPT_DIR="$(cd "$(dirname "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")" && pwd)"
BEZEL="$SCRIPT_DIR/assets/iPad mini - Starlight - Portrait.png"

GITHUB_RAW_BASE="https://raw.githubusercontent.com/robert-friedland/se-video-tools/main"

# Update subcommand
if [ "$1" = "update" ]; then
    echo "Updating composite_bezel..."
    curl -fsSL "${GITHUB_RAW_BASE}/composite_bezel.sh" -o "$SCRIPT_DIR/composite_bezel.sh.tmp" \
        && mv "$SCRIPT_DIR/composite_bezel.sh.tmp" "$SCRIPT_DIR/composite_bezel.sh" \
        && chmod +x "$SCRIPT_DIR/composite_bezel.sh"
    mkdir -p "$SCRIPT_DIR/assets"
    curl -fsSL "${GITHUB_RAW_BASE}/assets/iPad%20mini%20-%20Starlight%20-%20Portrait.png" \
        -o "$SCRIPT_DIR/assets/iPad mini - Starlight - Portrait.png"
    rm -f "$SCRIPT_DIR/iPad mini - Starlight - Portrait.png"
    if [ -d "$HOME/.claude/commands" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/commands/composite-bezel.md" \
            -o "$HOME/.claude/commands/composite-bezel.md"
        echo "Claude skill updated."
    fi
    BINARY_URL="https://github.com/robert-friedland/se-video-tools/releases/latest/download/composite_bezel_gpu"
    _BIN_TMP=$(mktemp /tmp/composite_bezel_gpu_XXXXXX)
    if curl -fL "$BINARY_URL" -o "$_BIN_TMP" 2>/dev/null && [ -s "$_BIN_TMP" ]; then
        mv "$_BIN_TMP" "$SCRIPT_DIR/composite_bezel_gpu"
        chmod +x "$SCRIPT_DIR/composite_bezel_gpu"
        codesign -s - "$SCRIPT_DIR/composite_bezel_gpu"
        xattr -d com.apple.quarantine "$SCRIPT_DIR/composite_bezel_gpu" 2>/dev/null || true
        echo "composite_bezel_gpu updated."
    else
        rm -f "$_BIN_TMP"
        if [ -x "$SCRIPT_DIR/composite_bezel_gpu" ]; then
            echo "Warning: composite_bezel_gpu download failed — keeping existing binary."
        else
            echo "Warning: composite_bezel_gpu download failed and no existing binary found. Build from source or attach a release binary."
        fi
    fi
    echo "Done."
    exit 0
fi

# Locate GPU binary — prefer co-located binary in install dir, fall back to PATH
if [ -f "$SCRIPT_DIR/composite_bezel_gpu" ] && [ -x "$SCRIPT_DIR/composite_bezel_gpu" ]; then
    GPU_BIN="$SCRIPT_DIR/composite_bezel_gpu"
elif command -v composite_bezel_gpu &>/dev/null; then
    GPU_BIN="$(command -v composite_bezel_gpu)"
else
    echo "Error: composite_bezel_gpu not found. composite_bezel requires Apple Silicon." >&2
    echo "Run 'composite_bezel update' to install the GPU binary." >&2
    exit 1
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
OUTPUT_WIDTH=""
BG_ROTATION_OVERRIDE=""
SCR_ROTATION_OVERRIDE=""

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
        --jobs)          shift 2 ;;  # accepted for compatibility; GPU uses single-pass pipeline
        --output-width)  OUTPUT_WIDTH="$2";    shift 2 ;;
        --bg-rotation)   BG_ROTATION_OVERRIDE="$2";  shift 2 ;;
        --scr-rotation)  SCR_ROTATION_OVERRIDE="$2"; shift 2 ;;
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
    echo "Warning: background effective dimensions ${BG_EFF_W}x${BG_EFF_H} are portrait, not landscape." >&2
    echo "  The bezel overlay may have negative coordinates and appear partially clipped off-screen. (continuing)" >&2
fi

# ── Probe screen recording ────────────────────────────────────────────────────
read -r SCR_W SCR_H SCR_BITRATE SCR_ROTATION SCR_R_FPS SCR_AVG_FPS < <(python3 - "$SCR" <<'PYEOF'
import sys, json, subprocess

result = subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0",
     "-show_entries", "stream=width,height,bit_rate,r_frame_rate,avg_frame_rate:stream_side_data=rotation",
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
r_fps   = d.get("r_frame_rate",   "0/0")
avg_fps = d.get("avg_frame_rate", "0/0")
print(w, h, bitrate, rotation, r_fps, avg_fps)
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
    echo "Warning: screen recording effective dimensions ${SCR_EFF_W}x${SCR_EFF_H} (ratio $(python3 -c "print(round($SCR_EFF_W/$SCR_EFF_H,3))")) don't match iPad mini portrait (expected ~${IPAD_RATIO} ±${RATIO_TOLERANCE}) (continuing)" >&2
fi

# ── Calculate dimensions ──────────────────────────────────────────────────────

# Output resolution: scale background if --output-width is set (even integers)
if [ -n "$OUTPUT_WIDTH" ]; then
    OUT_W=$(python3 -c "print(round(int('$OUTPUT_WIDTH') / 2) * 2)")
    OUT_H=$(python3 -c "print(round(int('$OUTPUT_WIDTH') * $BG_EFF_H / $BG_EFF_W / 2) * 2)")
else
    OUT_W=$BG_EFF_W
    OUT_H=$BG_EFF_H
fi

# Screen area within bezel canvas (89% of bezel, even integers)
SCREEN_W=$(python3 -c "print(round($BEZEL_W * $SCALE / 2) * 2)")
SCREEN_H=$(python3 -c "print(round($BEZEL_H * $SCALE / 2) * 2)")
X_OFF=$(( (BEZEL_W - SCREEN_W) / 2 ))
Y_OFF=$(( (BEZEL_H - SCREEN_H) / 2 ))

# Overlay dimensions (scaled bezel, even integers) — based on output height
OVL_H=$(python3 -c "print(round($OUT_H * $OVERLAY_SCALE / 2) * 2)")
OVL_W=$(python3 -c "print(round($OVL_H * $BEZEL_W / $BEZEL_H / 2) * 2)")

# Position: use explicit --x/--y if provided, otherwise default (right side, vertically centered)
if [ -n "$OVL_X_OVERRIDE" ]; then
    OVL_X="$OVL_X_OVERRIDE"
else
    OVL_X=$(( OUT_W - OVL_W - MARGIN ))
fi
if [ -n "$OVL_Y_OVERRIDE" ]; then
    OVL_Y="$OVL_Y_OVERRIDE"
else
    OVL_Y=$(( (OUT_H - OVL_H) / 2 ))
fi

# Output bitrate: 75% of background (higher than ipad_bezel.sh's 60% — two motion sources)
OUTPUT_BITRATE=$(python3 -c "print(int(float('$BG_BITRATE') * 0.75))")

# ── Durations ─────────────────────────────────────────────────────────────────
BG_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$BG" 2>/dev/null)
# Must probe original $SCR here, before any VFR reassignment below.
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
echo "Output size:     ${OUT_W}x${OUT_H}$([ -n "$OUTPUT_WIDTH" ] && echo " (--output-width; native ${BG_EFF_W}x${BG_EFF_H})" || echo " (native)")"
echo "Output:          $OUTPUT"
echo ""

# ── GPU compositing ────────────────────────────────────────────────────────────
# macOS mktemp requires X's at end; .mp4 extension added after randomization
_TMP=$(mktemp /tmp/composite_gpu_XXXXXX)
TEMP_VIDEO="${_TMP}.mp4"
mv "$_TMP" "$TEMP_VIDEO"
SCR_CFR_TMP=""
ORIG_SCR=""
cleanup() {
    rm -f "$TEMP_VIDEO"
    [ -n "$SCR_CFR_TMP" ] && rm -f "$SCR_CFR_TMP"
}
trap cleanup EXIT

# ── VFR detection ─────────────────────────────────────────────────────────────
IS_VFR=$(python3 -c "
import fractions
try:
    r = float(fractions.Fraction('$SCR_R_FPS'))
    a = float(fractions.Fraction('$SCR_AVG_FPS'))
    print('true' if r > 0 and a > 0 and abs(r - a) / r > 0.05 else 'false')
except Exception:
    print('false')
")

if [ "$IS_VFR" = "true" ]; then
    echo "Warning: screen recording is VFR (declared ${SCR_R_FPS} fps, actual avg ${SCR_AVG_FPS} fps). Converting to CFR before compositing..." >&2
    ORIG_SCR="$SCR"
    _SCR_CFR=$(mktemp /tmp/scr_cfr_XXXXXX)
    SCR_CFR_TMP="${_SCR_CFR}.mp4"
    mv "$_SCR_CFR" "$SCR_CFR_TMP"
    # -c:a copy preserves full audio from t=0; audio mux applies atrim via ORIG_SCR.
    # Do not add -ss or trim flags here.
    ffmpeg -i "$SCR" -vf "fps=${SCR_R_FPS}" -c:v h264_videotoolbox -q:v 65 -c:a copy \
        -y "$SCR_CFR_TMP" >/dev/null 2>&1 \
        || { echo "Error: CFR conversion failed" >&2; exit 1; }
    SCR="$SCR_CFR_TMP"
fi

# Compute audio atrim endpoints (both start AND end required to prevent audio > video)
BG_END_TIME=$(python3 -c "print(float('$BG_START') + float('$ACTIVE_DURATION'))")
SCR_END_TIME=$(python3 -c "print(float('$SCR_START') + float('$ACTIVE_DURATION'))")

# Reconstruct args from parsed variables (avoids third-positional OUTPUT conflicts)
GPU_ARGS=("$BG" "$SCR" --bezel "$BEZEL" --output "$TEMP_VIDEO")
GPU_ARGS+=(--bg-start "$BG_START" --scr-start "$SCR_START")
GPU_ARGS+=(--overlay-scale "$OVERLAY_SCALE" --margin "$MARGIN")
[ -n "$OVL_X_OVERRIDE" ] && GPU_ARGS+=(--x "$OVL_X_OVERRIDE")
[ -n "$OVL_Y_OVERRIDE" ] && GPU_ARGS+=(--y "$OVL_Y_OVERRIDE")
[ -n "$DURATION_OVERRIDE" ] && GPU_ARGS+=(--duration "$DURATION_OVERRIDE")
[ -n "$OUTPUT_WIDTH" ] && GPU_ARGS+=(--output-width "$OUTPUT_WIDTH")
[ -n "$BG_ROTATION_OVERRIDE" ]  && GPU_ARGS+=(--bg-rotation  "$BG_ROTATION_OVERRIDE")
[ -n "$SCR_ROTATION_OVERRIDE" ] && GPU_ARGS+=(--scr-rotation "$SCR_ROTATION_OVERRIDE")
GPU_ARGS+=(--audio "$AUDIO_MODE")

echo "GPU path: $GPU_BIN"
"$GPU_BIN" "${GPU_ARGS[@]}"
if [ $? -ne 0 ]; then echo "Error: GPU compositing failed" >&2; exit 1; fi

# Second pass: audio mux from original source files
# Uses both start AND end times in atrim to avoid audio duration > video duration
case "$AUDIO_MODE" in
    both)
        if [ "$BG_HAS_AUDIO" = "audio" ] && [ "$SCR_HAS_AUDIO" = "audio" ]; then
            AUDIO_FILTER="[1:a]atrim=${BG_START}:${BG_END_TIME},asetpts=PTS-STARTPTS[abg];\
[2:a]atrim=${SCR_START}:${SCR_END_TIME},asetpts=PTS-STARTPTS[ascr];\
[abg][ascr]amix=inputs=2:duration=shortest:normalize=0[aout]"
            AUDIO_MUXARGS=(-filter_complex "$AUDIO_FILTER" -map "[aout]" -c:a aac -b:a 192k)
        elif [ "$BG_HAS_AUDIO" = "audio" ]; then
            AUDIO_FILTER="[1:a]atrim=${BG_START}:${BG_END_TIME},asetpts=PTS-STARTPTS[aout]"
            AUDIO_MUXARGS=(-filter_complex "$AUDIO_FILTER" -map "[aout]" -c:a aac -b:a 128k)
        elif [ "$SCR_HAS_AUDIO" = "audio" ]; then
            AUDIO_FILTER="[2:a]atrim=${SCR_START}:${SCR_END_TIME},asetpts=PTS-STARTPTS[aout]"
            AUDIO_MUXARGS=(-filter_complex "$AUDIO_FILTER" -map "[aout]" -c:a aac -b:a 128k)
        else
            AUDIO_MUXARGS=(-an)
        fi ;;
    bg)
        AUDIO_FILTER="[1:a]atrim=${BG_START}:${BG_END_TIME},asetpts=PTS-STARTPTS[aout]"
        AUDIO_MUXARGS=(-filter_complex "$AUDIO_FILTER" -map "[aout]" -c:a aac -b:a 128k) ;;
    screen)
        AUDIO_FILTER="[2:a]atrim=${SCR_START}:${SCR_END_TIME},asetpts=PTS-STARTPTS[aout]"
        AUDIO_MUXARGS=(-filter_complex "$AUDIO_FILTER" -map "[aout]" -c:a aac -b:a 128k) ;;
    none)  AUDIO_MUXARGS=(-an) ;;
    *)
        echo "Error: --audio must be one of: both, bg, screen, none" >&2; exit 1 ;;
esac

ffmpeg -i "$TEMP_VIDEO" -i "$BG" -i "${ORIG_SCR:-$SCR}" \
    -map 0:v "${AUDIO_MUXARGS[@]}" \
    -c:v copy -tag:v hvc1 \
    -y "$OUTPUT" 2>&1
