#!/bin/bash
# iPad mini bezel overlay (GPU-accelerated via composite_bezel_gpu)
# Usage: ipad_bezel [--bg black|greenscreen|0xRRGGBB] input.mp4 [output.mp4]
#        ipad_bezel update

set -e

# Resolve real script location through symlinks (BASH_SOURCE[0] may be a symlink in homebrew/bin)
SCRIPT_DIR="$(cd "$(dirname "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")" && pwd)"
BEZEL="$SCRIPT_DIR/assets/iPad mini - Starlight - Portrait.png"

# Set this to your GitHub repo's raw URL once the repo is pushed
GITHUB_RAW_BASE="https://raw.githubusercontent.com/robert-friedland/se-video-tools/main"

# Update subcommand — pulls latest script, bezel PNG, GPU binary, and Claude skill from GitHub
if [ "$1" = "update" ]; then
    echo "Updating ipad_bezel..."
    curl -fsSL "${GITHUB_RAW_BASE}/ipad_bezel.sh" -o "$SCRIPT_DIR/ipad_bezel.sh.tmp" \
        && mv "$SCRIPT_DIR/ipad_bezel.sh.tmp" "$SCRIPT_DIR/ipad_bezel.sh" \
        && chmod +x "$SCRIPT_DIR/ipad_bezel.sh"
    mkdir -p "$SCRIPT_DIR/assets"
    curl -fsSL "${GITHUB_RAW_BASE}/assets/iPad%20mini%20-%20Starlight%20-%20Portrait.png" \
        -o "$SCRIPT_DIR/assets/iPad mini - Starlight - Portrait.png"
    rm -f "$SCRIPT_DIR/iPad mini - Starlight - Portrait.png"
    BINARY_URL="https://github.com/robert-friedland/se-video-tools/releases/latest/download/composite_bezel_gpu"
    curl -fL "$BINARY_URL" -o "$SCRIPT_DIR/composite_bezel_gpu" 2>/dev/null && {
        chmod +x "$SCRIPT_DIR/composite_bezel_gpu"
        codesign -s - "$SCRIPT_DIR/composite_bezel_gpu"
        xattr -d com.apple.quarantine "$SCRIPT_DIR/composite_bezel_gpu" 2>/dev/null || true
        echo "composite_bezel_gpu updated."
    } || echo "composite_bezel_gpu not available."
    if [ -d "$HOME/.claude/commands" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/commands/ipad-bezel.md" \
            -o "$HOME/.claude/commands/ipad-bezel.md"
        echo "Claude skill updated."
    fi
    echo "Done."
    exit 0
fi

# Require GPU binary (Apple Silicon only)
if ! command -v composite_bezel_gpu &>/dev/null; then
    echo "Error: composite_bezel_gpu not found. ipad_bezel requires Apple Silicon." >&2
    echo "Run 'ipad_bezel update' to install the GPU binary." >&2
    exit 1
fi

# Background color for the area around the bezel (default: black)
# Use --bg greenscreen for a chroma-key green you can key out in Resolve
BG_COLOR="black"

POSITIONALS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --bg)    BG_COLOR="$2"; shift 2 ;;
        --*)
            echo "Unknown option: $1"
            echo "Usage: $0 [--bg black|greenscreen|0xRRGGBB] input.mp4 [output.mp4]"
            exit 1 ;;
        *) POSITIONALS+=("$1"); shift ;;
    esac
done

if [ "$BG_COLOR" = "greenscreen" ]; then
    BG_COLOR="0x00B140"
fi

# Convert --bg value to bare 6-digit hex for --bg-color flag
case "$BG_COLOR" in
    black)    HEX_COLOR="000000" ;;
    0x*|0X*)  HEX_COLOR="${BG_COLOR#0[xX]}" ;;
    *)        HEX_COLOR="$BG_COLOR" ;;
esac

INPUT="${POSITIONALS[0]:-}"
OUTPUT="${POSITIONALS[1]:-${POSITIONALS[0]%.*}_bezeled.mp4}"

if [ -z "$INPUT" ]; then
    echo "Usage: $0 [--bg black|greenscreen|0xRRGGBB] input.mp4 [output.mp4]"
    exit 1
fi

if [ ! -f "$INPUT" ]; then
    echo "Error: input file not found: $INPUT"
    exit 1
fi

# Probe input: bitrate and duration
INPUT_BITRATE=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=bit_rate -of csv=p=0 "$INPUT" 2>/dev/null)
if [ -z "$INPUT_BITRATE" ] || [ "$INPUT_BITRATE" = "N/A" ]; then
    INPUT_BITRATE=$(ffprobe -v error -show_entries format=bit_rate \
        -of csv=p=0 "$INPUT" 2>/dev/null)
fi
if [ -z "$INPUT_BITRATE" ] || [ "$INPUT_BITRATE" = "N/A" ]; then
    INPUT_BITRATE=8000000
fi

DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT" 2>/dev/null)
if [ -z "$DURATION" ]; then
    echo "Error: could not probe input duration: $INPUT"
    exit 1
fi

HAS_AUDIO=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_type -of csv=p=0 "$INPUT" 2>/dev/null)

# Target 60% of input bitrate
OUTPUT_BITRATE=$(python3 -c "print(max(500000, int(float('$INPUT_BITRATE') * 0.6)))")

echo "Input:    $INPUT  (${DURATION}s @ ${INPUT_BITRATE}bps)"
echo "Background: #${HEX_COLOR}"
echo "Output:   $OUTPUT"
echo ""

# ── GPU compositing ────────────────────────────────────────────────────────────
_TMP=$(mktemp /tmp/ipad_bezel_XXXXXX)
TEMP_VIDEO="${_TMP}.mp4"
mv "$_TMP" "$TEMP_VIDEO"
trap 'rm -f "$TEMP_VIDEO"' EXIT

GPU_ARGS=("$INPUT" --bezel "$BEZEL" --output "$TEMP_VIDEO")
GPU_ARGS+=(--bg-color "$HEX_COLOR" --bitrate "$OUTPUT_BITRATE")

echo "GPU path: composite_bezel_gpu"
composite_bezel_gpu "${GPU_ARGS[@]}"
if [ $? -ne 0 ]; then echo "Error: GPU compositing failed" >&2; exit 1; fi

# ── Audio mux pass ─────────────────────────────────────────────────────────────
if [ "$HAS_AUDIO" = "audio" ]; then
    ffmpeg -i "$TEMP_VIDEO" -i "$INPUT" \
        -map 0:v \
        -filter_complex "[1:a]atrim=0:${DURATION},asetpts=PTS-STARTPTS[aout]" \
        -map "[aout]" -c:a aac -b:a 128k \
        -c:v copy -tag:v hvc1 \
        -y "$OUTPUT" 2>&1
else
    ffmpeg -i "$TEMP_VIDEO" -map 0:v -an -c:v copy -tag:v hvc1 -y "$OUTPUT" 2>/dev/null
fi

# ── Verify output duration ─────────────────────────────────────────────────────
OUTPUT_DURATION=$(ffprobe -v error -show_entries format=duration \
    -of csv=p=0 "$OUTPUT" 2>/dev/null)
DURATION_OK=$(python3 -c "print('true' if abs(float('$OUTPUT_DURATION') - float('$DURATION')) < 1.0 else 'false')")

if [ "$DURATION_OK" = "false" ]; then
    echo ""
    echo "ERROR: output duration (${OUTPUT_DURATION}s) doesn't match input (${DURATION}s)"
    exit 1
fi

echo ""
echo "Done: $OUTPUT (${OUTPUT_DURATION}s)"
