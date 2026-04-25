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
# Input JSON — two accepted shapes.
#
#   Array form (simplest):
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
# Fields:
#   source       absolute path to an MP4/MOV/etc. readable by ffprobe
#   start        seconds into the source where the clip begins
#   duration     seconds to keep from that source
#   label        optional — unused by Resolve on import but handy in the JSON
#   gap          seconds of empty timeline before the next clip (no source needed)
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
    sed -n '2,46p' "$SCRIPT_DIR/build_timeline.sh" | sed 's/^# \{0,1\}//'
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

# Normalize to {name, segments}
if isinstance(raw, list):
    segments = raw
elif isinstance(raw, dict):
    segments = raw.get("segments", [])
    if raw.get("name"):
        seq_name = raw["name"]
else:
    sys.exit("Error: top-level JSON must be an array or object with 'segments'.")

if not segments:
    sys.exit("Error: no segments in input.")

# ── Probe each unique source once ────────────────────────────────────────────
def ffprobe_source(path):
    if not os.path.isfile(path):
        sys.exit(f"Error: source not found: {path}")
    # One ffprobe call returns everything we need as JSON.
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

unique_sources = []
seen = set()
for seg in segments:
    if "gap" in seg:
        continue
    src = seg.get("source")
    if not src:
        sys.exit(f"Error: segment missing 'source': {seg}")
    if src not in seen:
        seen.add(src)
        unique_sources.append(src)

if not unique_sources:
    sys.exit("Error: no clip segments (only gaps).")

probed = {p: ffprobe_source(p) for p in unique_sources}

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

# Audio channels may differ between sources in practice; warn rather than fail.
channel_counts = {s["channels"] for s in probed.values()}
if len(channel_counts) > 1:
    print(
        f"warning: sources have different audio channel counts {sorted(channel_counts)}; "
        f"using {ref['channels']} for the sequence.", file=sys.stderr,
    )
seq_channels = ref["channels"]

# ── Frame-rate → (timebase, ntsc) ────────────────────────────────────────────
# xmeml v5: integer timebase with optional ntsc=TRUE for .976/.97 variants.
def resolve_rate(fr_num, fr_den):
    # NTSC families expressed as X000/1001
    if fr_den == 1001:
        # fr_num is X * 1000 for X in {24, 30, 60}, roughly
        base = round(fr_num / 1000)
        return base, True
    # Exact integer fps
    if fr_den == 1:
        return fr_num, False
    # Fallback: use float approximation
    fps = fr_num / fr_den
    if abs(fps - round(fps)) < 1e-3:
        return int(round(fps)), False
    # Treat as NTSC: bump up and flag
    return int(round(fps + 0.5)), True

timebase, ntsc = resolve_rate(ref["fr_num"], ref["fr_den"])
ntsc_str = "TRUE" if ntsc else "FALSE"

# Frame conversion: 1 xmeml frame = 1 tick of the sequence timebase, real duration
# = 1001 / (timebase * 1000) s when ntsc, else 1 / timebase s.
if ntsc:
    FRAMES_PER_SEC_NUM = timebase * 1000
    FRAMES_PER_SEC_DEN = 1001
else:
    FRAMES_PER_SEC_NUM = timebase
    FRAMES_PER_SEC_DEN = 1

def sec_to_frames(sec):
    return round(sec * FRAMES_PER_SEC_NUM / FRAMES_PER_SEC_DEN)

# ── Source TC normalization: DF semicolons → colons, blank → placeholder ─────
tc_warned = []
def normalize_tc(tc, path):
    if not tc:
        tc_warned.append(path)
        return "00:00:00:00"
    # `08:48:34;11` → `08:48:34:11`
    return tc.replace(";", ":")

# ── File IDs (shared per source) and per-instance clip IDs ───────────────────
file_id_for = {p: f"{os.path.basename(p)} f" for p in unique_sources}
instance_counter = {}  # path -> int

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
    tc = normalize_tc(src_meta["timecode"], path)
    fid = file_id_for[path]
    name = os.path.basename(path)
    return f"""<file id="{xml_escape(fid)}">
                            <duration>{src_dur_frames}</duration>
                            {RATE_BLOCK}
                            <name>{xml_escape(name)}</name>
                            <pathurl>{pathurl(path)}</pathurl>
                            <timecode>
                                <string>{tc}</string>
                                <displayformat>NDF</displayformat>
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

# ── Walk segments and build clipitems ────────────────────────────────────────
video_clips, audio_clips = [], []
file_full_emitted = set()
timeline_pos = 0

for seg in segments:
    if "gap" in seg:
        gap_sec = float(seg["gap"])
        timeline_pos += sec_to_frames(gap_sec)
        continue

    src = seg["source"]
    ss = float(seg.get("start", 0))
    dur = float(seg["duration"])
    meta = probed[src]
    name = os.path.basename(src)

    inst = instance_counter.get(src, 0)
    instance_counter[src] = inst + 1

    vid_id = f"{name} v{inst}"
    aud_id = f"{name} a{inst}"
    fid = file_id_for[src]

    src_in = sec_to_frames(ss)
    dur_frames = sec_to_frames(dur)
    src_out = src_in + dur_frames
    tl_start = timeline_pos
    tl_end = tl_start + dur_frames
    src_dur_frames = sec_to_frames(meta["duration"])

    if src not in file_full_emitted:
        file_block = file_block_full(src, meta)
        file_full_emitted.add(src)
    else:
        file_block = f'<file id="{xml_escape(fid)}"/>'

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
                        <link>
                            <linkclipref>{xml_escape(vid_id)}</linkclipref>
                        </link>
                        <link>
                            <linkclipref>{xml_escape(aud_id)}</linkclipref>
                        </link>
                        <comments/>
                    </clipitem>"""
    video_clips.append(v)

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
    audio_clips.append(a)

    timeline_pos = tl_end

total_dur = timeline_pos

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
                <track>
{chr(10).join(video_clips)}
                    <enabled>TRUE</enabled>
                    <locked>FALSE</locked>
                </track>
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
                <track>
{chr(10).join(audio_clips)}
                    <enabled>TRUE</enabled>
                    <locked>FALSE</locked>
                </track>
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

# Warn once if any sources lacked embedded TC — likely root cause of future
# "clips not found" reports from the same user who hit this in v1 of the
# GEV rough cut (placeholder TCs fail Resolve's TC match).
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
    print(f"wrote {output_path}  ({len(video_clips)} clips, {dur_sec:.2f}s, timebase={timebase}, ntsc={ntsc_str})")
PYEOF
