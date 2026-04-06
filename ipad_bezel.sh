#!/bin/bash
# iPad mini bezel overlay
# Usage: ipad_bezel [--bg black|greenscreen|0xRRGGBB] [--jobs N] input.mp4 [output.mp4]
#        ipad_bezel update

set -e

# Resolve real script location through symlinks (BASH_SOURCE[0] may be a symlink in homebrew/bin)
SCRIPT_DIR="$(cd "$(dirname "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")" && pwd)"
BEZEL="$SCRIPT_DIR/assets/iPad mini - Starlight - Portrait.png"

# Set this to your GitHub repo's raw URL once the repo is pushed
GITHUB_RAW_BASE="https://raw.githubusercontent.com/robert-friedland/se-video-tools/main"

# Update subcommand — pulls latest script, bezel PNG, and Claude skill from GitHub
if [ "$1" = "update" ]; then
    echo "Updating ipad_bezel..."
    curl -fsSL "${GITHUB_RAW_BASE}/ipad_bezel.sh" -o "$SCRIPT_DIR/ipad_bezel.sh.tmp" \
        && mv "$SCRIPT_DIR/ipad_bezel.sh.tmp" "$SCRIPT_DIR/ipad_bezel.sh" \
        && chmod +x "$SCRIPT_DIR/ipad_bezel.sh"
    mkdir -p "$SCRIPT_DIR/assets"
    curl -fsSL "${GITHUB_RAW_BASE}/assets/iPad%20mini%20-%20Starlight%20-%20Portrait.png" \
        -o "$SCRIPT_DIR/assets/iPad mini - Starlight - Portrait.png"
    rm -f "$SCRIPT_DIR/iPad mini - Starlight - Portrait.png"
    if [ -d "$HOME/.claude/commands" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/commands/ipad-bezel.md" \
            -o "$HOME/.claude/commands/ipad-bezel.md"
        echo "Claude skill updated."
    fi
    echo "Done. Run 'ipad_bezel --version' to verify."
    exit 0
fi

# Background color for the area around the bezel (default: black)
# Use --bg greenscreen for a chroma-key green you can key out in Resolve
BG_COLOR="black"
JOBS_OVERRIDE=""

POSITIONALS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --bg)    BG_COLOR="$2"; shift 2 ;;
        --jobs)  JOBS_OVERRIDE="$2"; shift 2 ;;
        --*)
            echo "Unknown option: $1"
            echo "Usage: $0 [--bg black|greenscreen|0xRRGGBB] [--jobs N] input.mp4 [output.mp4]"
            exit 1 ;;
        *) POSITIONALS+=("$1"); shift ;;
    esac
done

if [ "$BG_COLOR" = "greenscreen" ]; then
    BG_COLOR="0x00B140"
fi

INPUT="${POSITIONALS[0]:-}"
OUTPUT="${POSITIONALS[1]:-${POSITIONALS[0]%.*}_bezeled.mp4}"

# Bezel image dimensions (1780x2550)
BEZEL_W=1780
BEZEL_H=2550

# Expected iPad mini portrait aspect ratio (width/height = 1488/2266 ≈ 0.6567)
# We allow ±5% tolerance to cover different recording resolutions
IPAD_RATIO=0.6567
RATIO_TOLERANCE=0.05

# Scale factor: footage is scaled to this % of the bezel canvas before overlaying
# 89% matches the Resolve workflow where footage at 89% sits perfectly behind the bezel
SCALE=0.89

if [ -z "$INPUT" ]; then
    echo "Usage: $0 input.mov [output.mov]"
    exit 1
fi

if [ ! -f "$INPUT" ]; then
    echo "Error: input file not found: $INPUT"
    exit 1
fi

# Probe input: dimensions, bitrate, and rotation (rotation lives in side_data, not stream entries)
read -r INPUT_W INPUT_H INPUT_BITRATE ROTATION < <(python3 - "$INPUT" <<'PYEOF'
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

# Fall back to container bitrate if stream bitrate is unavailable
if [ -z "$INPUT_BITRATE" ] || [ "$INPUT_BITRATE" = "N/A" ]; then
    INPUT_BITRATE=$(ffprobe -v error -show_entries format=bit_rate \
        -of csv=p=0 "$INPUT" 2>/dev/null)
fi

# Apply rotation to get effective display dimensions
if [ "$ROTATION" = "-90" ] || [ "$ROTATION" = "90" ] || \
   [ "$ROTATION" = "270" ] || [ "$ROTATION" = "-270" ]; then
    EFF_W=$INPUT_H
    EFF_H=$INPUT_W
else
    EFF_W=$INPUT_W
    EFF_H=$INPUT_H
fi

# Validate aspect ratio against iPad mini portrait (~0.6567), portrait orientation required
VALID_RATIO=$(python3 -c "
ratio = $EFF_W / $EFF_H
expected = $IPAD_RATIO
diff = abs(ratio - expected) / expected
print('true' if diff <= $RATIO_TOLERANCE else 'false')
")

if [ "$VALID_RATIO" = "false" ]; then
    echo "Warning: effective dimensions ${EFF_W}x${EFF_H} (ratio $(python3 -c "print(round($EFF_W/$EFF_H,3))")) don't match iPad mini portrait (expected ~${IPAD_RATIO} ±${RATIO_TOLERANCE})"
    read -p "Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi

# Calculate screen area size (89% of bezel canvas)
SCREEN_W=$(python3 -c "print(round($BEZEL_W * $SCALE / 2) * 2)")
SCREEN_H=$(python3 -c "print(round($BEZEL_H * $SCALE / 2) * 2)")

# Center offsets
X_OFF=$(( (BEZEL_W - SCREEN_W) / 2 ))
Y_OFF=$(( (BEZEL_H - SCREEN_H) / 2 ))

# Parallel chunk processing using trim filters — frame-accurate, no splitting artifacts.
# Each worker reads the full input and trims its segment via the filter graph.
DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT" 2>/dev/null)

if [ -z "$DURATION" ]; then
    echo "Error: could not probe input duration: $INPUT"
    exit 1
fi

LOGICAL_CPUS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
if [ -n "$JOBS_OVERRIDE" ]; then
    N_JOBS="$JOBS_OVERRIDE"
else
    N_JOBS=$LOGICAL_CPUS
fi
N_JOBS=$(python3 -c "print(max(1, min($N_JOBS, int(float('$DURATION')))))")
CHUNK_DUR=$(python3 -c "print(float('$DURATION') / $N_JOBS)")

# Target 60% of input bitrate — HEVC's efficiency over H.264 compensates,
# and the bezel adds visual complexity that would otherwise inflate the file
OUTPUT_BITRATE=$(python3 -c "print(int(float('$INPUT_BITRATE') * 0.6))")

HAS_AUDIO=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_type -of csv=p=0 "$INPUT" 2>/dev/null)

INPUT_FPS_RAW=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate -of csv=p=0 "$INPUT" 2>/dev/null)
TOTAL_FRAMES=$(python3 -c "
from fractions import Fraction
raw = '$INPUT_FPS_RAW'.strip().rstrip(',')
try:
    fps = float(Fraction(raw)) if raw else 30.0
    if fps == 0: fps = 30.0
except Exception:
    fps = 30.0
if fps == 30.0 and not raw:
    import sys; print('Warning: could not probe FPS, progress bar may be inaccurate', file=sys.stderr)
print(max(1, int(fps * float('$DURATION') + 0.5)))
")

echo "Bezel canvas:  ${BEZEL_W}x${BEZEL_H}"
echo "Screen area:   ${SCREEN_W}x${SCREEN_H} at offset ${X_OFF},${Y_OFF}"
echo "Input:         ${INPUT_W}x${INPUT_H} (effective ${EFF_W}x${EFF_H}, rotation ${ROTATION}°) @ ${INPUT_BITRATE}bps"
echo "Background:    ${BG_COLOR}"
echo "Parallel jobs: ${N_JOBS} (of ${LOGICAL_CPUS} logical CPUs; use --jobs N to override)"
echo "Output:        $OUTPUT"
echo ""

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

echo "Processing ${N_JOBS} chunks in parallel..."

PIDS=()
for i in $(seq 0 $((N_JOBS - 1))); do
    START=$(python3 -c "print($i * $CHUNK_DUR)")
    END=$(python3 -c "print(min(($i + 1) * $CHUNK_DUR, float('$DURATION')))")
    CHUNK_OUT="$WORK_DIR/chunk_$(printf '%04d' $i).mp4"

    if [ "$HAS_AUDIO" = "audio" ]; then
        FILTER="[0:v]trim=${START}:${END},setpts=PTS-STARTPTS,\
scale=${SCREEN_W}:${SCREEN_H}:force_original_aspect_ratio=decrease,\
pad=${SCREEN_W}:${SCREEN_H}:(ow-iw)/2:(oh-ih)/2:black[footage];\
[footage]pad=${BEZEL_W}:${BEZEL_H}:${X_OFF}:${Y_OFF}:${BG_COLOR}[canvas];\
[canvas][1:v]overlay=0:0[out];\
[0:a]atrim=${START}:${END},asetpts=PTS-STARTPTS[aout]"
        AUDIO_ARGS=(-map "[aout]" -c:a aac -b:a 128k)
    else
        FILTER="[0:v]trim=${START}:${END},setpts=PTS-STARTPTS,\
scale=${SCREEN_W}:${SCREEN_H}:force_original_aspect_ratio=decrease,\
pad=${SCREEN_W}:${SCREEN_H}:(ow-iw)/2:(oh-ih)/2:black[footage];\
[footage]pad=${BEZEL_W}:${BEZEL_H}:${X_OFF}:${Y_OFF}:${BG_COLOR}[canvas];\
[canvas][1:v]overlay=0:0[out]"
        AUDIO_ARGS=()
    fi

    ffmpeg \
        -progress "$WORK_DIR/progress_${i}.txt" \
        -i "$INPUT" -i "$BEZEL" \
        -filter_complex "$FILTER" \
        -map "[out]" "${AUDIO_ARGS[@]}" \
        -c:v hevc_videotoolbox -b:v "${OUTPUT_BITRATE}" -tag:v hvc1 \
        -y "$CHUNK_OUT" \
        > "$WORK_DIR/chunk_${i}.log" 2>&1 &
    PIDS+=($!)
done

# ── Progress bar ──────────────────────────────────────────────────────────────
START_SECS=$(date +%s)
declare -a CHUNK_DONE
for i in $(seq 0 $((N_JOBS - 1))); do CHUNK_DONE[$i]=0; done
DONE_COUNT=0
FAILED=false

while [ $DONE_COUNT -lt $N_JOBS ]; do
    sleep 0.3
    DONE_COUNT=0

    for i in "${!PIDS[@]}"; do
        if [ "${CHUNK_DONE[$i]}" = "1" ]; then
            DONE_COUNT=$((DONE_COUNT + 1)); continue
        fi
        PROG="$WORK_DIR/progress_${i}.txt"
        if [ -f "$PROG" ] && grep -q '^progress=end$' "$PROG" 2>/dev/null; then
            CHUNK_DONE[$i]=1; DONE_COUNT=$((DONE_COUNT + 1))
            if ! wait "${PIDS[$i]}" 2>/dev/null; then FAILED=true; fi
        elif ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
            CHUNK_DONE[$i]=1; DONE_COUNT=$((DONE_COUNT + 1))
            if ! wait "${PIDS[$i]}"; then FAILED=true; fi
        fi
    done

    BAR_LINE=$(python3 - "$WORK_DIR" "$N_JOBS" "$TOTAL_FRAMES" \
                         "$(($(date +%s) - START_SECS))" "$DONE_COUNT" <<'PYEOF'
import sys
work_dir, n_jobs, total_frames = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
elapsed, done_chunks = int(sys.argv[4]), int(sys.argv[5])

total_done, speed_vals = 0, []
for i in range(n_jobs):
    try:
        lines = open(f"{work_dir}/progress_{i}.txt").read().splitlines()
        frames = [int(l.split('=',1)[1]) for l in lines if l.startswith('frame=')]
        if frames: total_done += frames[-1]
        for l in lines:
            if l.startswith('speed='):
                try: speed_vals.append(float(l.split('=',1)[1].strip().rstrip('x')))
                except: pass
    except: pass

# Force 100% when all chunks complete (avoids stalling at 99% due to rounding)
if done_chunks == n_jobs:
    pct = 100
else:
    pct = min(99, int(total_done * 100 / total_frames)) if total_frames else 0

W = 26
bar = '█' * int(W * pct / 100) + '░' * (W - int(W * pct / 100))
def fmt_duration(s):
    s = int(s)
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    if h:   return f"{h}h {m:02d}m {sec:02d}s"
    elif m: return f"{m}m {sec:02d}s"
    else:   return f"{sec}s"

speed = f"  {sum(speed_vals)/len(speed_vals):.1f}x" if speed_vals else ""
eta_secs = int(elapsed*(100-pct)/pct) if pct >= 3 and pct < 100 and elapsed > 0 else None
eta   = f"  eta ~{fmt_duration(eta_secs)}" if eta_secs is not None else ""
elapsed_str = fmt_duration(elapsed)
print(f"  [{bar}] {pct:3d}%  {elapsed_str} elapsed{eta}{speed}", end='')
PYEOF
    )
    printf "\r%s\033[K" "$BAR_LINE"
done

printf "\n"
if $FAILED; then
    echo "One or more chunks failed. Check logs in: $WORK_DIR"
    for i in "${!CHUNK_DONE[@]}"; do
        log="$WORK_DIR/chunk_${i}.log"
        [ -f "$log" ] && echo "  chunk $i: $log"
    done
    exit 1
fi

# Merge chunks
echo ""
echo "Merging ${N_JOBS} chunks..."
printf "file '%s'\n" "$WORK_DIR"/chunk_????.mp4 > "$WORK_DIR/concat.txt"
ffmpeg -f concat -safe 0 -i "$WORK_DIR/concat.txt" -c copy -y "$OUTPUT" 2>/dev/null

# Verify output duration matches input
OUTPUT_DURATION=$(ffprobe -v error -show_entries format=duration \
    -of csv=p=0 "$OUTPUT" 2>/dev/null)
DURATION_OK=$(python3 -c "print('true' if abs(float('$OUTPUT_DURATION') - float('$DURATION')) < 1.0 else 'false')")

if [ "$DURATION_OK" = "false" ]; then
    echo ""
    echo "ERROR: output duration (${OUTPUT_DURATION}s) doesn't match input (${DURATION}s)"
    echo "The bezeled file may have errors. Check logs in: $WORK_DIR"
    exit 1
fi

echo ""
echo "Done: $OUTPUT (${OUTPUT_DURATION}s)"
