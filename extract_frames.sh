#!/bin/bash
# extract_frames — extract N evenly-distributed frames from a video
# Usage: extract_frames <video> <num_frames> <output_dir> [options]
#
# Options:
#   --start <sec>      Window start in seconds (default: 0)
#   --stop  <sec>      Window end in seconds (default: full duration)
#   --scale <px>       Output width in pixels (default: 640)
#   --accurate         Use accurate seek (slower but frame-exact; default: fast seek)
#   --crop <W:H:X:Y>   Crop filter applied before scaling
#   --prefix <str>     Filename prefix (default: frame)

set -e

if [ $# -lt 3 ]; then
    echo "Usage: extract_frames <video> <num_frames> <output_dir> [options]" >&2
    exit 1
fi

VIDEO="$1"
NUM_FRAMES="$2"
OUTPUT_DIR="$3"
shift 3

# Defaults
START=""
STOP=""
SCALE=640
ACCURATE=0
CROP=""
PREFIX="frame"

while [ $# -gt 0 ]; do
    case "$1" in
        --start)  START="$2";  shift 2 ;;
        --stop)   STOP="$2";   shift 2 ;;
        --scale)  SCALE="$2";  shift 2 ;;
        --accurate) ACCURATE=1; shift ;;
        --crop)   CROP="$2";   shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Validate
if [ ! -f "$VIDEO" ]; then
    echo "Error: video not found: $VIDEO" >&2
    exit 1
fi
if ! [[ "$NUM_FRAMES" =~ ^[0-9]+$ ]] || [ "$NUM_FRAMES" -lt 1 ]; then
    echo "Error: num_frames must be a positive integer" >&2
    exit 1
fi
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "Error: output directory does not exist: $OUTPUT_DIR" >&2
    exit 1
fi

# Resolve start/stop
if [ -z "$START" ]; then
    START=0
fi
if [ -z "$STOP" ]; then
    STOP=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$VIDEO" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$STOP" ] || [ "$(echo "$STOP <= 0" | bc -l)" = "1" ]; then
        echo "Error: could not determine video duration" >&2
        exit 1
    fi
fi

WINDOW=$(echo "$STOP - $START" | bc -l)
if [ "$(echo "$WINDOW <= 0" | bc -l)" = "1" ]; then
    echo "Error: --stop ($STOP) must be greater than --start ($START)" >&2
    exit 1
fi

# Build vf filter string
if [ -n "$CROP" ]; then
    VF="crop=${CROP},scale=${SCALE}:-1"
else
    VF="scale=${SCALE}:-1"
fi

# Extract frames using half-step formula: T_i = start + (i + 0.5) * window / N
for i in $(seq 0 $(( NUM_FRAMES - 1 ))); do
    T=$(echo "$START + ($i + 0.5) * $WINDOW / $NUM_FRAMES" | bc -l)
    # Round to 1 decimal for filename readability
    T_LABEL=$(printf "%.1f" "$T")
    SEQ=$(printf "%03d" $(( i + 1 )))
    OUTFILE="${OUTPUT_DIR}/${PREFIX}_${SEQ}_${T_LABEL}s.jpg"

    if [ "$ACCURATE" = "1" ]; then
        # Accurate seek: -i before -ss (decodes from previous keyframe)
        ffmpeg -i "$VIDEO" -ss "$T" -frames:v 1 -vf "$VF" -q:v 2 "$OUTFILE" -y 2>/dev/null
    else
        # Fast seek: -ss before -i (lands on nearest keyframe)
        ffmpeg -ss "$T" -i "$VIDEO" -frames:v 1 -vf "$VF" -q:v 2 "$OUTFILE" -y 2>/dev/null
    fi
done

echo "Extracted $NUM_FRAMES frames to $OUTPUT_DIR"
