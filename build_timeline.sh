#!/bin/bash
# build_timeline — generate a DaVinci Resolve-compatible Final Cut Pro 7 XML
# (xmeml v5) timeline from a JSON cut list.
#
# Usage: build_timeline [--name NAME] <input.json> [output.xml]
#        build_timeline update
#
# Options:
#   --name NAME     Sequence name to embed in the XML. Default: input basename,
#                   or "Timeline" when reading stdin.
#   -h, --help      Show this help.
#
# Input JSON — three accepted shapes.
#
#   Array form (simplest, single video track):
#     [
#       {"source": "/abs/path.mp4", "start": 57.60, "duration": 12.40, "label": "Beat 1"},
#       {"gap": 0.60},
#       {"source": "/abs/path2.mp4", "start": 234.84, "duration": 10.16}
#     ]
#
#   Object form (lets you set sequence name inline):
#     {
#       "name": "My Rough Cut",
#       "segments": [ ... same as array form ... ]
#     }
#
#   Multi-track form (V1 talking heads + V2 B-roll overlay, etc.):
#     {
#       "name": "My Rough Cut",
#       "tracks": {
#         "V1": [ ... same shape as segments above ... ],
#         "V2": [
#           {"timeline_start": 2.5, "duration": 7.5, "source": "/abs/broll.mp4", "source_in": 4.0}
#         ]
#       },
#       "audio": {
#         "A1": [
#           {"timeline_start": 0.0, "duration": 60.0, "source": "/abs/narration.mp3", "source_in": 0.0}
#         ]
#       }
#     }
#
# Fields (V1 segment):
#   source       absolute path to an MP4/MOV/etc. readable by ffprobe
#   start        seconds into the source where the clip begins
#   duration     seconds to keep from that source
#   label        optional — unused by Resolve on import but handy in the JSON
#   gap          seconds of empty timeline before the next clip (no source needed)
#
# Fields (V2+ overlay segment):
#   timeline_start  seconds from sequence start where the overlay begins (absolute)
#   duration        seconds the overlay covers
#   source          absolute path
#   source_in       seconds into the source where the overlay begins (default 0)
#   label           optional
#
# Fields (audio segment, A1+):
#   timeline_start  seconds from sequence start (absolute)
#   duration        seconds the audio covers
#   source          absolute path to an audio file (mp3/wav/m4a/etc. readable by ffprobe)
#   source_in       seconds into the source where the segment begins (default 0)
#   label           optional
#
# V2+ tracks: absolute timeline positions, no `gap`, video-only (no linked audio),
# rendered as full-frame replacement at 100% scale.
#
# `audio` top-level key (optional): when present, the timeline's audio is exactly
# what's in this block — V1's implicit audio is muted. Use this for AI-narrated
# sizzle reels where V1 is purely visual and a separate narration track drives
# the audio. When the `audio` key is absent, the current behavior (V1 video
# clipitems link to their own audio on a single track) is preserved.
#
# Input path accepts `-` for stdin. Output path accepts `-` for stdout; if
# omitted, the output path is derived from the input (`foo.json` → `foo.xml`).
#
# Requires: ffprobe, python3. Sources must all share one frame rate and one
# resolution; mismatched sources are rejected with a message naming the offender.
#
# A note on timecodes: Resolve's xmeml importer validates the `<file><timecode>`
# string against the media's embedded SMPTE TC. This tool ffprobes each source
# for its real TC. If a source has no embedded TC, the tool falls back to
# 00:00:00:00 and prints a warning — that path is correct when the source
# genuinely lacks TC (Resolve treats the clip as starting at zero), but it will
# break import for sources that *do* carry TC that the probe missed.

set -e

# Resolve real script location through symlinks
SCRIPT_DIR="$(cd "$(dirname "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")" && pwd)"

GITHUB_RAW_BASE="https://raw.githubusercontent.com/robert-friedland/se-video-tools/main"

# ── Update subcommand ────────────────────────────────────────────────────────
if [ "${1:-}" = "update" ]; then
    echo "Updating build_timeline..."
    curl -fsSL "${GITHUB_RAW_BASE}/build_timeline.sh" -o "$SCRIPT_DIR/build_timeline.sh.tmp" \
        && mv "$SCRIPT_DIR/build_timeline.sh.tmp" "$SCRIPT_DIR/build_timeline.sh" \
        && chmod +x "$SCRIPT_DIR/build_timeline.sh"
    if [ -d "$HOME/.claude/commands" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/commands/build-timeline.md" \
            -o "$HOME/.claude/commands/build-timeline.md"
        echo "Claude skill updated."
    fi
    echo "Done."
    exit 0
fi

usage() {
    sed -n '2,60p' "$SCRIPT_DIR/build_timeline.sh" | sed 's/^# \{0,1\}//'
}

# ── Argument parsing ─────────────────────────────────────────────────────────
NAME=""
POSITIONALS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --name)   NAME="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --*)      echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)        POSITIONALS+=("$1"); shift ;;
    esac
done

if [ "${#POSITIONALS[@]}" -lt 1 ] || [ "${#POSITIONALS[@]}" -gt 2 ]; then
    echo "Error: expected <input.json> [output.xml]" >&2
    usage >&2
    exit 1
fi

INPUT="${POSITIONALS[0]}"
OUTPUT="${POSITIONALS[1]:-}"

if [ -z "$OUTPUT" ]; then
    if [ "$INPUT" = "-" ]; then
        OUTPUT="-"
    else
        # Derive from input: strip final extension, append .xml
        OUTPUT="${INPUT%.*}.xml"
        # Guard against input with no extension (would overwrite itself)
        if [ "$OUTPUT" = "$INPUT" ]; then
            OUTPUT="${INPUT}.xml"
        fi
    fi
fi

# Default sequence name
if [ -z "$NAME" ]; then
    if [ "$INPUT" = "-" ]; then
        NAME="Timeline"
    else
        NAME="$(basename "${INPUT%.*}")"
    fi
fi

# ── Dependency checks ────────────────────────────────────────────────────────
command -v ffprobe >/dev/null || { echo "Error: ffprobe not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "Error: python3 not found" >&2; exit 1; }

# Stdin (`-`) gets buffered to a tempfile because the python heredoc below
# would otherwise consume stdin itself.
_STDIN_TMP=""
if [ "$INPUT" = "-" ]; then
    _STDIN_TMP=$(mktemp /tmp/build_timeline_stdin_XXXXXX.json)
    cat > "$_STDIN_TMP"
    INPUT="$_STDIN_TMP"
    trap 'rm -f "$_STDIN_TMP"' EXIT INT TERM
fi

# ── Generate XML via Python ──────────────────────────────────────────────────
python3 - "$INPUT" "$OUTPUT" "$NAME" <<'PYEOF'
import sys, json, os, subprocess, re
from pathlib import Path
from urllib.parse import quote

input_path, output_path, seq_name = sys.argv[1:]

# ── Load JSON (always a file path; stdin was buffered to a tempfile in shell) ─
with open(input_path) as f:
    raw = json.load(f)

# Normalize to tracks_in: {1: [V1 segs], 2: [V2 segs], ...}.
# Three input shapes are supported: bare list (V1 only), {name, segments} (V1
# only), or {name, tracks: {V1: [...], V2: [...], ...}} (multi-track).
def _track_key_to_int(k):
    s = str(k).strip().upper()
    if s.startswith("V") or s.startswith("A"):
        s = s[1:]
    return int(s)

if isinstance(raw, list):
    tracks_in = {1: raw}
elif isinstance(raw, dict):
    if raw.get("name"):
        seq_name = raw["name"]
    if "segments" in raw and "tracks" in raw:
        sys.exit("Error: specify only one of 'segments' or 'tracks', not both.")
    if "tracks" in raw:
        tracks_raw = raw["tracks"]
        if not isinstance(tracks_raw, dict):
            sys.exit("Error: 'tracks' must be an object mapping track keys (V1, V2, ...) to segment lists.")
        try:
            tracks_in = {_track_key_to_int(k): v for k, v in tracks_raw.items()}
        except ValueError:
            sys.exit("Error: 'tracks' keys must be V1, V2, ... or 1, 2, ...")
        if 1 not in tracks_in:
            sys.exit("Error: 'tracks' must include V1.")
    else:
        tracks_in = {1: raw.get("segments", [])}
else:
    sys.exit("Error: top-level JSON must be an array, or an object with 'segments' or 'tracks'.")

if not tracks_in.get(1):
    sys.exit("Error: V1 has no segments.")

# Optional `audio` block — when present, the timeline's audio is exactly what's
# in this block (V1's implicit audio is muted).
audio_tracks_in = {}
if isinstance(raw, dict) and "audio" in raw:
    audio_raw = raw["audio"]
    if not isinstance(audio_raw, dict):
        sys.exit("Error: 'audio' must be an object mapping track keys (A1, A2, ...) to segment lists.")
    try:
        audio_tracks_in = {_track_key_to_int(k): v for k, v in audio_raw.items()}
    except ValueError:
        sys.exit("Error: 'audio' keys must be A1, A2, ... or 1, 2, ...")
    for tidx, segs in audio_tracks_in.items():
        if not isinstance(segs, list):
            sys.exit(f"Error: 'audio' track A{tidx} must be a list of segments.")
        for seg in segs:
            if "timeline_start" not in seg:
                sys.exit(f"Error: audio segment missing 'timeline_start': {seg}")
            if "duration" not in seg:
                sys.exit(f"Error: audio segment missing 'duration': {seg}")
            if not seg.get("source"):
                sys.exit(f"Error: audio segment missing 'source': {seg}")
has_explicit_audio = bool(audio_tracks_in)

# ── Probe each unique source once (across all tracks) ────────────────────────
def ffprobe_source(path):
    if not os.path.isfile(path):
        sys.exit(f"Error: source not found: {path}")
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries",
        "stream=r_frame_rate,width,height:stream_tags=timecode:format=duration",
        "-of", "json", path,
    ]
    vid = json.loads(subprocess.check_output(cmd))
    cmd_a = [
        "ffprobe", "-v", "error",
        "-select_streams", "a:0",
        "-show_entries", "stream=channels",
        "-of", "json", path,
    ]
    aud = json.loads(subprocess.check_output(cmd_a))

    v_stream = (vid.get("streams") or [{}])[0]
    a_stream = (aud.get("streams") or [{}])[0]

    r_frame_rate = v_stream.get("r_frame_rate", "30/1")
    num_str, den_str = r_frame_rate.split("/")
    fr_num, fr_den = int(num_str), int(den_str)
    width = int(v_stream.get("width") or 1920)
    height = int(v_stream.get("height") or 1080)
    tc = (v_stream.get("tags") or {}).get("timecode") or ""
    duration = float((vid.get("format") or {}).get("duration") or 0.0)
    channels = int(a_stream.get("channels") or 2)

    return {
        "path": path,
        "fr_num": fr_num, "fr_den": fr_den,
        "width": width, "height": height,
        "timecode": tc,
        "duration": duration,
        "channels": channels,
    }

def ffprobe_audio_source(path):
    if not os.path.isfile(path):
        sys.exit(f"Error: audio source not found: {path}")
    cmd = [
        "ffprobe", "-v", "error",
        "-select_streams", "a:0",
        "-show_entries",
        "stream=channels,sample_rate,codec_name:stream_tags=timecode:format=duration",
        "-of", "json", path,
    ]
    aud = json.loads(subprocess.check_output(cmd))
    a_stream = (aud.get("streams") or [{}])[0]
    if not a_stream:
        sys.exit(f"Error: audio source has no audio stream: {path}")
    channels = int(a_stream.get("channels") or 2)
    sample_rate = int(a_stream.get("sample_rate") or 48000)
    tc = (a_stream.get("tags") or {}).get("timecode") or ""
    duration = float((aud.get("format") or {}).get("duration") or 0.0)
    return {
        "path": path,
        "channels": channels,
        "sample_rate": sample_rate,
        "timecode": tc,
        "duration": duration,
    }

unique_sources = []
seen = set()
for track_idx, segs in tracks_in.items():
    for seg in segs:
        if "gap" in seg:
            continue
        src = seg.get("source")
        if not src:
            sys.exit(f"Error: segment missing 'source' (track V{track_idx}): {seg}")
        if src not in seen:
            seen.add(src)
            unique_sources.append(src)

if not unique_sources:
    sys.exit("Error: no clip segments (only gaps).")

probed = {p: ffprobe_source(p) for p in unique_sources}

# Audio-only sources (from `audio` block) are probed separately. They have no
# video stream and are excluded from the frame-rate / resolution check below.
unique_audio_sources = []
audio_seen = set()
for track_idx, segs in audio_tracks_in.items():
    for seg in segs:
        src = seg["source"]
        if src not in audio_seen:
            audio_seen.add(src)
            unique_audio_sources.append(src)
audio_probed = {p: ffprobe_audio_source(p) for p in unique_audio_sources}

# ── Enforce shared frame rate and resolution; name the offender if not ───────
ref = probed[unique_sources[0]]
for p in unique_sources[1:]:
    s = probed[p]
    if (s["fr_num"], s["fr_den"]) != (ref["fr_num"], ref["fr_den"]):
        sys.exit(
            f"Error: frame rate mismatch — '{unique_sources[0]}' is "
            f"{ref['fr_num']}/{ref['fr_den']} but '{p}' is {s['fr_num']}/{s['fr_den']}. "
            "Conform sources to one frame rate before building a timeline."
        )
    if (s["width"], s["height"]) != (ref["width"], ref["height"]):
        sys.exit(
            f"Error: resolution mismatch — '{unique_sources[0]}' is "
            f"{ref['width']}x{ref['height']} but '{p}' is {s['width']}x{s['height']}."
        )

# Audio channel count: compute from V1 sources only — overlay (V2+) sources
# may legitimately have 0 audio channels (silent inserts) and shouldn't pollute
# the sequence audio count or trigger spurious mismatch warnings.
v1_sources = []
v1_seen = set()
for seg in tracks_in[1]:
    if "gap" in seg:
        continue
    s = seg["source"]
    if s not in v1_seen:
        v1_seen.add(s)
        v1_sources.append(s)
v1_channel_counts = {probed[p]["channels"] for p in v1_sources}
if len(v1_channel_counts) > 1:
    print(
        f"warning: V1 sources have different audio channel counts {sorted(v1_channel_counts)}; "
        f"using {probed[v1_sources[0]]['channels']} for the sequence.", file=sys.stderr,
    )
seq_channels = probed[v1_sources[0]]["channels"]

# ── Frame-rate → (timebase, ntsc) ────────────────────────────────────────────
# xmeml v5: integer timebase with optional ntsc=TRUE for .976/.97 variants.
def resolve_rate(fr_num, fr_den):
    if fr_den == 1001:
        base = round(fr_num / 1000)
        return base, True
    if fr_den == 1:
        return fr_num, False
    fps = fr_num / fr_den
    if abs(fps - round(fps)) < 1e-3:
        return int(round(fps)), False
    return int(round(fps + 0.5)), True

timebase, ntsc = resolve_rate(ref["fr_num"], ref["fr_den"])
ntsc_str = "TRUE" if ntsc else "FALSE"

if ntsc:
    FRAMES_PER_SEC_NUM = timebase * 1000
    FRAMES_PER_SEC_DEN = 1001
else:
    FRAMES_PER_SEC_NUM = timebase
    FRAMES_PER_SEC_DEN = 1

def sec_to_frames(sec):
    return round(sec * FRAMES_PER_SEC_NUM / FRAMES_PER_SEC_DEN)

# ── Source TC normalization ──────────────────────────────────────────────────
# Drop-frame TC uses a semicolon between seconds and frames (08:37:01;20).
# Davinci's xmeml import uses the file's <timecode><displayformat> to compute
# source-in offsets — so DF sources MUST be tagged DF, otherwise the
# DF/NDF accumulated drift (~1ms per second of TC value) shifts every clip's
# playback by the source's TC × 0.001 — easily 30+ seconds for wall-clock TCs.
tc_warned = []
def normalize_tc(tc, path):
    """Returns (tc_string, displayformat). Preserves semicolon for DF."""
    if not tc:
        tc_warned.append(path)
        return "00:00:00:00", "NDF"
    is_df = ";" in tc
    return tc, ("DF" if is_df else "NDF")

# ── File IDs (shared per source across tracks) and per-(source, track) instance counts ─
file_id_for = {p: f"{os.path.basename(p)} f" for p in unique_sources}
for p in unique_audio_sources:
    if p not in file_id_for:
        file_id_for[p] = f"{os.path.basename(p)} f"
instance_counter = {}  # (path, track) -> int

# ── XML snippet helpers ──────────────────────────────────────────────────────
RATE_BLOCK = f"<rate>\n                            <timebase>{timebase}</timebase>\n                            <ntsc>{ntsc_str}</ntsc>\n                        </rate>"
RATE_BLOCK_SEQ = f"<rate>\n            <timebase>{timebase}</timebase>\n            <ntsc>{ntsc_str}</ntsc>\n        </rate>"
RATE_BLOCK_INNER = f"<rate>\n                                <timebase>{timebase}</timebase>\n                                <ntsc>{ntsc_str}</ntsc>\n                            </rate>"
RATE_BLOCK_TC = f"<rate>\n                                    <timebase>{timebase}</timebase>\n                                    <ntsc>{ntsc_str}</ntsc>\n                                </rate>"
RATE_BLOCK_FMT = f"<rate>\n                            <timebase>{timebase}</timebase>\n                            <ntsc>{ntsc_str}</ntsc>\n                        </rate>"

def pathurl(p):
    return "file://" + quote(p)

def xml_escape(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
                 .replace(">", "&gt;").replace('"', "&quot;"))

def video_filters(dur_frames):
    return f"""                        <filter>
                            <enabled>TRUE</enabled>
                            <start>0</start>
                            <end>{dur_frames}</end>
                            <effect>
                                <name>Basic Motion</name>
                                <effectid>basic</effectid>
                                <effecttype>motion</effecttype>
                                <mediatype>video</mediatype>
                                <effectcategory>motion</effectcategory>
                                <parameter>
                                    <name>Scale</name>
                                    <parameterid>scale</parameterid>
                                    <value>100</value>
                                    <valuemin>0</valuemin>
                                    <valuemax>10000</valuemax>
                                </parameter>
                                <parameter>
                                    <name>Center</name>
                                    <parameterid>center</parameterid>
                                    <value>
                                        <horiz>0</horiz>
                                        <vert>0</vert>
                                    </value>
                                </parameter>
                                <parameter>
                                    <name>Rotation</name>
                                    <parameterid>rotation</parameterid>
                                    <value>0</value>
                                    <valuemin>-100000</valuemin>
                                    <valuemax>100000</valuemax>
                                </parameter>
                                <parameter>
                                    <name>Anchor Point</name>
                                    <parameterid>centerOffset</parameterid>
                                    <value>
                                        <horiz>0</horiz>
                                        <vert>0</vert>
                                    </value>
                                </parameter>
                            </effect>
                        </filter>
                        <filter>
                            <enabled>TRUE</enabled>
                            <start>0</start>
                            <end>{dur_frames}</end>
                            <effect>
                                <name>Crop</name>
                                <effectid>crop</effectid>
                                <effecttype>motion</effecttype>
                                <mediatype>video</mediatype>
                                <effectcategory>motion</effectcategory>
                                <parameter>
                                    <name>left</name>
                                    <parameterid>left</parameterid>
                                    <value>0</value>
                                    <valuemin>0</valuemin>
                                    <valuemax>100</valuemax>
                                </parameter>
                                <parameter>
                                    <name>right</name>
                                    <parameterid>right</parameterid>
                                    <value>0</value>
                                    <valuemin>0</valuemin>
                                    <valuemax>100</valuemax>
                                </parameter>
                                <parameter>
                                    <name>top</name>
                                    <parameterid>top</parameterid>
                                    <value>0</value>
                                    <valuemin>0</valuemin>
                                    <valuemax>100</valuemax>
                                </parameter>
                                <parameter>
                                    <name>bottom</name>
                                    <parameterid>bottom</parameterid>
                                    <value>0</value>
                                    <valuemin>0</valuemin>
                                    <valuemax>100</valuemax>
                                </parameter>
                            </effect>
                        </filter>
                        <filter>
                            <enabled>TRUE</enabled>
                            <start>0</start>
                            <end>{dur_frames}</end>
                            <effect>
                                <name>Opacity</name>
                                <effectid>opacity</effectid>
                                <effecttype>motion</effecttype>
                                <mediatype>video</mediatype>
                                <effectcategory>motion</effectcategory>
                                <parameter>
                                    <name>opacity</name>
                                    <parameterid>opacity</parameterid>
                                    <value>100</value>
                                    <valuemin>0</valuemin>
                                    <valuemax>100</valuemax>
                                </parameter>
                            </effect>
                        </filter>"""

def audio_filters(dur_frames):
    return f"""                        <filter>
                            <enabled>TRUE</enabled>
                            <start>0</start>
                            <end>{dur_frames}</end>
                            <effect>
                                <name>Audio Levels</name>
                                <effectid>audiolevels</effectid>
                                <effecttype>audiolevels</effecttype>
                                <mediatype>audio</mediatype>
                                <effectcategory>audiolevels</effectcategory>
                                <parameter>
                                    <name>Level</name>
                                    <parameterid>level</parameterid>
                                    <value>1</value>
                                    <valuemin>1e-05</valuemin>
                                    <valuemax>31.6228</valuemax>
                                </parameter>
                            </effect>
                        </filter>
                        <filter>
                            <enabled>TRUE</enabled>
                            <start>0</start>
                            <end>{dur_frames}</end>
                            <effect>
                                <name>Audio Pan</name>
                                <effectid>audiopan</effectid>
                                <effecttype>audiopan</effecttype>
                                <mediatype>audio</mediatype>
                                <effectcategory>audiopan</effectcategory>
                                <parameter>
                                    <name>Pan</name>
                                    <parameterid>pan</parameterid>
                                    <value>0</value>
                                    <valuemin>-1</valuemin>
                                    <valuemax>1</valuemax>
                                </parameter>
                            </effect>
                        </filter>"""

def file_block_full(path, src_meta):
    src_dur_frames = sec_to_frames(src_meta["duration"])
    tc, tc_displayformat = normalize_tc(src_meta["timecode"], path)
    fid = file_id_for[path]
    name = os.path.basename(path)
    return f"""<file id="{xml_escape(fid)}">
                            <duration>{src_dur_frames}</duration>
                            {RATE_BLOCK}
                            <name>{xml_escape(name)}</name>
                            <pathurl>{pathurl(path)}</pathurl>
                            <timecode>
                                <string>{tc}</string>
                                <displayformat>{tc_displayformat}</displayformat>
                                {RATE_BLOCK_TC}
                            </timecode>
                            <media>
                                <video>
                                    <duration>{src_dur_frames}</duration>
                                    <samplecharacteristics>
                                        <width>{src_meta["width"]}</width>
                                        <height>{src_meta["height"]}</height>
                                    </samplecharacteristics>
                                </video>
                                <audio>
                                    <channelcount>{src_meta["channels"]}</channelcount>
                                </audio>
                            </media>
                        </file>"""

def file_block_audio_full(path, src_meta):
    """File block for an audio-only source. No <video> in <media>."""
    src_dur_frames = sec_to_frames(src_meta["duration"])
    tc, tc_displayformat = normalize_tc(src_meta["timecode"], path)
    fid = file_id_for[path]
    name = os.path.basename(path)
    return f"""<file id="{xml_escape(fid)}">
                            <duration>{src_dur_frames}</duration>
                            {RATE_BLOCK}
                            <name>{xml_escape(name)}</name>
                            <pathurl>{pathurl(path)}</pathurl>
                            <timecode>
                                <string>{tc}</string>
                                <displayformat>{tc_displayformat}</displayformat>
                                {RATE_BLOCK_TC}
                            </timecode>
                            <media>
                                <audio>
                                    <samplecharacteristics>
                                        <samplerate>{src_meta["sample_rate"]}</samplerate>
                                        <depth>16</depth>
                                    </samplecharacteristics>
                                    <channelcount>{src_meta["channels"]}</channelcount>
                                </audio>
                            </media>
                        </file>"""

# ── Walk segments per track and build clipitems ──────────────────────────────
# `file_full_emitted` is keyed per-source (NOT per-(source, track)) — the full
# <file> block emits once on the first occurrence of a source ACROSS ALL tracks;
# subsequent occurrences (other tracks, repeat instances) emit <file id=".."/> ref.
video_tracks = {}   # track_idx -> [clipitem string, ...]
audio_tracks = {}   # track_idx -> [clipitem string, ...]   (V1 only currently)
file_full_emitted = set()
all_end_frames = []  # union over all tracks; sequence <duration> = max
total_clip_count = 0

for track_idx in sorted(tracks_in.keys()):
    segs = tracks_in[track_idx]
    video_tracks.setdefault(track_idx, [])
    if track_idx == 1:
        audio_tracks.setdefault(1, [])
        timeline_pos = 0  # V1 uses sequential cursor with optional gaps

    for seg in segs:
        if "gap" in seg:
            if track_idx != 1:
                sys.exit(f"Error: 'gap' segments are only allowed on V1 (got track V{track_idx}).")
            timeline_pos += sec_to_frames(float(seg["gap"]))
            continue

        src = seg["source"]
        meta = probed[src]
        name = os.path.basename(src)

        if track_idx == 1:
            ss = float(seg.get("start", 0))
            dur = float(seg["duration"])
            tl_start = timeline_pos
        else:
            # V2+: absolute timeline_start, optional source_in
            if "timeline_start" not in seg:
                sys.exit(f"Error: V{track_idx} segment missing 'timeline_start': {seg}")
            tl_start_sec = float(seg["timeline_start"])
            ss = float(seg.get("source_in", 0))
            dur = float(seg["duration"])
            tl_start = sec_to_frames(tl_start_sec)

        dur_frames = sec_to_frames(dur)
        src_in = sec_to_frames(ss)
        src_out = src_in + dur_frames
        tl_end = tl_start + dur_frames
        src_dur_frames = sec_to_frames(meta["duration"])

        # IDs: track-1 keeps legacy format ("Foo.mp4 v0") so single-V1 output is
        # byte-equal to the pre-multitrack tool. Track 2+ uses a track-prefixed
        # format ("Foo.mp4 v2_0") so V2 reuses of a V1 source don't collide.
        key = (src, track_idx)
        inst = instance_counter.get(key, 0)
        instance_counter[key] = inst + 1
        if track_idx == 1:
            vid_id = f"{name} v{inst}"
            aud_id = f"{name} a{inst}"
        else:
            vid_id = f"{name} v{track_idx}_{inst}"
            aud_id = f"{name} a{track_idx}_{inst}"
        fid = file_id_for[src]

        if src not in file_full_emitted:
            file_block = file_block_full(src, meta)
            file_full_emitted.add(src)
        else:
            file_block = f'<file id="{xml_escape(fid)}"/>'

        # V2+ video clipitems carry NO <link> element. xmeml allows unlinked
        # clipitems; this avoids any dangling-ref hazard between tracks.
        # When `audio` is provided explicitly, V1 video does NOT emit an audio
        # link either — the V1 audio clipitem won't exist.
        if track_idx == 1 and not has_explicit_audio:
            link_block = f"""                        <link>
                            <linkclipref>{xml_escape(vid_id)}</linkclipref>
                        </link>
                        <link>
                            <linkclipref>{xml_escape(aud_id)}</linkclipref>
                        </link>
"""
        else:
            link_block = ""

        v = f"""                    <clipitem id="{xml_escape(vid_id)}">
                        <name>{xml_escape(name)}</name>
                        <duration>{src_dur_frames}</duration>
                        {RATE_BLOCK}
                        <start>{tl_start}</start>
                        <end>{tl_end}</end>
                        <enabled>TRUE</enabled>
                        <in>{src_in}</in>
                        <out>{src_out}</out>
                        {file_block}
                        <compositemode>normal</compositemode>
{video_filters(dur_frames)}
{link_block}                        <comments/>
                    </clipitem>"""
        video_tracks[track_idx].append(v)
        all_end_frames.append(tl_end)
        total_clip_count += 1

        if track_idx == 1 and not has_explicit_audio:
            a = f"""                    <clipitem id="{xml_escape(aud_id)}">
                        <name>{xml_escape(name)}</name>
                        <duration>{src_dur_frames}</duration>
                        {RATE_BLOCK}
                        <start>{tl_start}</start>
                        <end>{tl_end}</end>
                        <enabled>TRUE</enabled>
                        <in>{src_in}</in>
                        <out>{src_out}</out>
                        <file id="{xml_escape(fid)}"/>
                        <sourcetrack>
                            <mediatype>audio</mediatype>
                            <trackindex>1</trackindex>
                        </sourcetrack>
{audio_filters(dur_frames)}
                        <link>
                            <linkclipref>{xml_escape(vid_id)}</linkclipref>
                            <mediatype>video</mediatype>
                        </link>
                        <link>
                            <linkclipref>{xml_escape(aud_id)}</linkclipref>
                        </link>
                        <comments/>
                    </clipitem>"""
            audio_tracks[1].append(a)
        if track_idx == 1:
            timeline_pos = tl_end

# Process explicit audio segments (Mode 1: narration on A1, V1 audio muted).
if has_explicit_audio:
    for track_idx in sorted(audio_tracks_in.keys()):
        audio_tracks.setdefault(track_idx, [])
        for seg in audio_tracks_in[track_idx]:
            src = seg["source"]
            meta = audio_probed[src]
            name = os.path.basename(src)
            tl_start_sec = float(seg["timeline_start"])
            ss = float(seg.get("source_in", 0))
            dur = float(seg["duration"])
            tl_start = sec_to_frames(tl_start_sec)
            dur_frames = sec_to_frames(dur)
            src_in = sec_to_frames(ss)
            src_out = src_in + dur_frames
            tl_end = tl_start + dur_frames
            src_dur_frames = sec_to_frames(meta["duration"])

            key = (src, f"a{track_idx}")
            inst = instance_counter.get(key, 0)
            instance_counter[key] = inst + 1
            aud_id = f"{name} a{track_idx}_{inst}"
            fid = file_id_for[src]

            if src not in file_full_emitted:
                file_block = file_block_audio_full(src, meta)
                file_full_emitted.add(src)
            else:
                file_block = f'<file id="{xml_escape(fid)}"/>'

            a = f"""                    <clipitem id="{xml_escape(aud_id)}">
                        <name>{xml_escape(name)}</name>
                        <duration>{src_dur_frames}</duration>
                        {RATE_BLOCK}
                        <start>{tl_start}</start>
                        <end>{tl_end}</end>
                        <enabled>TRUE</enabled>
                        <in>{src_in}</in>
                        <out>{src_out}</out>
                        {file_block}
                        <sourcetrack>
                            <mediatype>audio</mediatype>
                            <trackindex>1</trackindex>
                        </sourcetrack>
{audio_filters(dur_frames)}
                        <comments/>
                    </clipitem>"""
            audio_tracks[track_idx].append(a)
            all_end_frames.append(tl_end)

total_dur = max(all_end_frames) if all_end_frames else 0

# Build one <track> block per video track index, in ascending order
# (V1 = first/bottom, V2 = second/top in Resolve's video stack).
video_track_blocks = []
for tidx in sorted(video_tracks.keys()):
    clips_str = chr(10).join(video_tracks[tidx])
    block = f"""                <track>
{clips_str}
                    <enabled>TRUE</enabled>
                    <locked>FALSE</locked>
                </track>"""
    video_track_blocks.append(block)
video_tracks_xml = chr(10).join(video_track_blocks)

# Emit one <track> block per audio track index. When `audio_tracks` is
# empty (no V1 audio AND no explicit audio block), still emit an empty A1
# placeholder so Resolve's importer doesn't choke on a missing audio track.
audio_track_indices = sorted(audio_tracks.keys()) if audio_tracks else [1]
audio_track_blocks = []
for tidx in audio_track_indices:
    clips_str = chr(10).join(audio_tracks.get(tidx, []))
    block = f"""                <track>
{clips_str}
                    <enabled>TRUE</enabled>
                    <locked>FALSE</locked>
                </track>"""
    audio_track_blocks.append(block)
audio_tracks_xml = chr(10).join(audio_track_blocks)

xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE xmeml>
<xmeml version="5">
    <sequence>
        <name>{xml_escape(seq_name)}</name>
        <duration>{total_dur}</duration>
        {RATE_BLOCK_SEQ}
        <in>-1</in>
        <out>-1</out>
        <timecode>
            <string>01:00:00:00</string>
            <frame>108000</frame>
            <displayformat>NDF</displayformat>
            {RATE_BLOCK_SEQ}
        </timecode>
        <media>
            <video>
{video_tracks_xml}
                <format>
                    <samplecharacteristics>
                        <width>{ref["width"]}</width>
                        <height>{ref["height"]}</height>
                        <pixelaspectratio>square</pixelaspectratio>
                        {RATE_BLOCK_FMT}
                        <codec>
                            <appspecificdata>
                                <appname>Final Cut Pro</appname>
                                <appmanufacturer>Apple Inc.</appmanufacturer>
                                <data>
                                    <qtcodec/>
                                </data>
                            </appspecificdata>
                        </codec>
                    </samplecharacteristics>
                </format>
            </video>
            <audio>
{audio_tracks_xml}
            </audio>
        </media>
    </sequence>
</xmeml>
"""

if output_path == "-":
    sys.stdout.write(xml)
else:
    with open(output_path, "w") as f:
        f.write(xml)

if tc_warned:
    print(
        f"warning: {len(tc_warned)} source(s) have no embedded SMPTE timecode; "
        f"using 00:00:00:00. Resolve import will work if the sources truly lack "
        f"a TC, but will refuse to match if ffprobe missed one. Affected: "
        f"{', '.join(os.path.basename(p) for p in tc_warned)}",
        file=sys.stderr,
    )

if output_path != "-":
    dur_sec = total_dur * FRAMES_PER_SEC_DEN / FRAMES_PER_SEC_NUM
    v_summary = ", ".join(f"V{t}={len(video_tracks[t])}" for t in sorted(video_tracks.keys()))
    a_summary_parts = [f"A{t}={len(audio_tracks[t])}" for t in sorted(audio_tracks.keys()) if audio_tracks[t]]
    a_summary = (", " + ", ".join(a_summary_parts)) if a_summary_parts else ""
    print(f"wrote {output_path}  ({total_clip_count} clips [{v_summary}{a_summary}], {dur_sec:.2f}s, timebase={timebase}, ntsc={ntsc_str})")
PYEOF
