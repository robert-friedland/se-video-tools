#!/bin/bash
# bridge_broll — pad V1 talking-head cuts and generate a contiguous V2 b-roll
# track from a per-beat shot plan, so V1 gaps don't show as black flashes.
#
# Usage: bridge_broll [options] <input.json> [output.json]
#        bridge_broll update
#
# Options:
#   --v1-lead SEC        V1 cut padding before each cut (default 0.10)
#   --v1-trail SEC       V1 cut padding after each cut (default 0.20)
#   --v2-head-show SEC   How long to show speaker on V1 before V2 starts on
#                        beat 1 (default 1.0)
#   --v2-tail-show SEC   How long to leave V1 visible at the end before
#                        timeline ends (default 0.5)
#   --v2-clearance SEC   Safety margin from each V2 source's end (default 0.34
#                        — ~10 frames at 29.97; Resolve rejects clips whose
#                        source out exceeds the file's frame count)
#   -h, --help           Show this help.
#
# Pipeline position (after resolve_phrases, before build_timeline):
#
#   resolve_phrases cuts.json - | bridge_broll - | build_timeline - rough.xml
#
# Input — JSON in the multi-track shape with two extras at the top level:
#
#   {
#     "name": "My Rough Cut",
#     "tracks": {
#       "V1": [
#         {"source": "/abs/path1.mp4", "start": 88.83, "duration": 12.49, "label": "Beat 1"},
#         {"gap": 0.4},
#         {"source": "/abs/path2.mp4", "start": 128.90, "duration": 11.18, "label": "Beat 2"},
#         ...
#       ]
#     },
#     "v2_plan": [
#       [
#         {"source": "/abs/broll1.mp4", "source_in": 0.0, "label": "pov recording"},
#         {"source": "/abs/broll2.mp4", "source_in": 0.0, "label": "recording in app"}
#       ],
#       [
#         {"source": "/abs/broll3.mp4", "source_in": 0.0, "label": "checklist"}
#       ],
#       ...
#     ]
#   }
#
# `v2_plan` is a list of per-beat shot lists, in the same order as V1 non-gap
# entries. Length must match the V1 beat count exactly. Each shot is
# `{source, source_in?, label?}`. `source_in` defaults to 0; `label` is optional.
#
# Behavior:
#   1. Each V1 cut gets padded: start -= v1_lead, duration += v1_lead + v1_trail.
#      This widens cuts so word edges don't clip.
#   2. V2 is rebuilt from v2_plan to be CONTIGUOUS from t = v2_head_show to
#      t = (last beat end) - v2_tail_show. V2 segments transition at the
#      midpoint of each V1 gap so V1 gaps are fully covered.
#   3. Within each beat's V2 span, shots are distributed proportionally,
#      capped by `source_dur - source_in - v2_clearance`. If a shot caps,
#      its leftover time is redistributed to uncapped shots in the same beat.
#   4. If a beat's source budget is below its V2 span, the tool exits with
#      a clear error naming the beat and the deficit. Add more shots, or
#      pick segments with more headroom.
#
# Output — same JSON, with:
#   - tracks.V1 padded in place
#   - tracks.V2 populated with `{timeline_start, duration, source, source_in, label}`
#   - top-level `v2_plan` and `bridge_broll_options` stripped
#
# `<input.json>` accepts `-` for stdin. `<output.json>` accepts `-` for stdout.
# Without an explicit output, `foo.json` → `foo.bridged.json`.
#
# Requires: ffprobe, python3.

set -e

# Resolve real script location through symlinks
SCRIPT_DIR="$(cd "$(dirname "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")" && pwd)"

GITHUB_RAW_BASE="https://raw.githubusercontent.com/robert-friedland/se-video-tools/main"

# ── Update subcommand ────────────────────────────────────────────────────────
if [ "${1:-}" = "update" ]; then
    echo "Updating bridge_broll..."
    curl -fsSL "${GITHUB_RAW_BASE}/bridge_broll.sh" -o "$SCRIPT_DIR/bridge_broll.sh.tmp" \
        && mv "$SCRIPT_DIR/bridge_broll.sh.tmp" "$SCRIPT_DIR/bridge_broll.sh" \
        && chmod +x "$SCRIPT_DIR/bridge_broll.sh"
    if [ -d "$HOME/.claude/commands" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/commands/interview-rough-cut.md" \
            -o "$HOME/.claude/commands/interview-rough-cut.md"
        echo "Claude skill updated."
    fi
    echo "Done."
    exit 0
fi

usage() {
    sed -n '2,55p' "$SCRIPT_DIR/bridge_broll.sh" | sed 's/^# \{0,1\}//'
}

# ── Argument parsing ─────────────────────────────────────────────────────────
V1_LEAD="0.10"
V1_TRAIL="0.20"
V2_HEAD_SHOW="1.0"
V2_TAIL_SHOW="0.5"
V2_CLEARANCE="0.34"
POSITIONALS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --v1-lead)        V1_LEAD="$2"; shift 2 ;;
        --v1-trail)       V1_TRAIL="$2"; shift 2 ;;
        --v2-head-show)   V2_HEAD_SHOW="$2"; shift 2 ;;
        --v2-tail-show)   V2_TAIL_SHOW="$2"; shift 2 ;;
        --v2-clearance)   V2_CLEARANCE="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        --*)              echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)                POSITIONALS+=("$1"); shift ;;
    esac
done

if [ "${#POSITIONALS[@]}" -lt 1 ] || [ "${#POSITIONALS[@]}" -gt 2 ]; then
    echo "Error: expected <input.json> [output.json]" >&2
    usage >&2
    exit 1
fi

INPUT="${POSITIONALS[0]}"
OUTPUT="${POSITIONALS[1]:-}"

if [ -z "$OUTPUT" ]; then
    if [ "$INPUT" = "-" ]; then
        OUTPUT="-"
    else
        STEM="${INPUT%.*}"
        if [ "$STEM" = "$INPUT" ]; then
            OUTPUT="${INPUT}.bridged.json"
        else
            OUTPUT="${STEM}.bridged.json"
        fi
    fi
fi

# Dependency checks
command -v ffprobe >/dev/null || { echo "Error: ffprobe not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "Error: python3 not found" >&2; exit 1; }

# Buffer stdin
_STDIN_TMP=""
if [ "$INPUT" = "-" ]; then
    _STDIN_TMP=$(mktemp /tmp/bridge_broll_stdin_XXXXXX.json)
    cat > "$_STDIN_TMP"
    INPUT="$_STDIN_TMP"
    trap 'rm -f "$_STDIN_TMP"' EXIT INT TERM
fi

# ── Bridge logic via Python ──────────────────────────────────────────────────
python3 - "$INPUT" "$OUTPUT" "$V1_LEAD" "$V1_TRAIL" "$V2_HEAD_SHOW" "$V2_TAIL_SHOW" "$V2_CLEARANCE" <<'PYEOF'
import sys, json, os, subprocess

(input_path, output_path,
 v1_lead_s, v1_trail_s, v2_head_show_s, v2_tail_show_s, v2_clearance_s) = sys.argv[1:]
V1_LEAD     = float(v1_lead_s)
V1_TRAIL    = float(v1_trail_s)
V2_HEAD     = float(v2_head_show_s)
V2_TAIL     = float(v2_tail_show_s)
V2_CLR      = float(v2_clearance_s)

with open(input_path) as f:
    raw = json.load(f)

if not isinstance(raw, dict):
    sys.exit("Error: input must be an object with 'tracks' and 'v2_plan'.")

tracks = raw.get("tracks")
if not isinstance(tracks, dict) or "V1" not in tracks:
    sys.exit("Error: input.tracks.V1 is required.")

v2_plan = raw.get("v2_plan")
if not isinstance(v2_plan, list):
    sys.exit("Error: top-level 'v2_plan' is required (list of per-beat shot lists).")

# Allow per-input override of options via top-level "bridge_broll_options"
opts = raw.get("bridge_broll_options") or {}
if "v1_lead"      in opts: V1_LEAD = float(opts["v1_lead"])
if "v1_trail"     in opts: V1_TRAIL = float(opts["v1_trail"])
if "v2_head_show" in opts: V2_HEAD = float(opts["v2_head_show"])
if "v2_tail_show" in opts: V2_TAIL = float(opts["v2_tail_show"])
if "v2_clearance" in opts: V2_CLR = float(opts["v2_clearance"])

v1 = tracks["V1"]

# ── Validate V1 is fully resolved (no phrase/near remaining) ─────────────────
for i, seg in enumerate(v1):
    if not isinstance(seg, dict):
        sys.exit(f"Error: V1#{i+1} not an object")
    if "gap" in seg:
        if not isinstance(seg["gap"], (int, float)) or seg["gap"] < 0:
            sys.exit(f"Error: V1#{i+1} gap must be non-negative number")
        continue
    if "phrase" in seg:
        sys.exit(
            f"Error: V1#{i+1} still has a 'phrase' field — run resolve_phrases first.\n"
            f"  Pipeline: resolve_phrases cuts.json - | bridge_broll - | build_timeline - out.xml"
        )
    if "source" not in seg or "start" not in seg or "duration" not in seg:
        sys.exit(f"Error: V1#{i+1} requires source/start/duration after resolution: {seg}")

# Count V1 beats (non-gap entries) and verify v2_plan length matches
v1_beats = [seg for seg in v1 if "gap" not in seg]
if len(v2_plan) != len(v1_beats):
    sys.exit(
        f"Error: v2_plan has {len(v2_plan)} beat plans but V1 has {len(v1_beats)} non-gap "
        f"cuts. Each beat needs a plan (use [] for an intentionally empty beat)."
    )

# ── Pad V1 cuts in place ─────────────────────────────────────────────────────
v1_padded = []
for seg in v1:
    if "gap" in seg:
        v1_padded.append(dict(seg))
        continue
    new_seg = dict(seg)
    new_seg["start"]    = round(float(seg["start"])    - V1_LEAD, 3)
    new_seg["duration"] = round(float(seg["duration"]) + V1_LEAD + V1_TRAIL, 3)
    v1_padded.append(new_seg)

# ── Compute beat boundaries on the padded timeline ───────────────────────────
beats = []  # (label, t_start, t_end, gap_before, gap_after)
t = 0.0
gap_before = 0.0
v1_iter = list(v1_padded)
for idx, seg in enumerate(v1_iter):
    if "gap" in seg:
        # gap accumulates between beats; remembered as "gap_after" of prev / "gap_before" of next
        if beats:
            beats[-1] = beats[-1][:4] + (float(seg["gap"]),)  # set gap_after of previous beat
        gap_before = float(seg["gap"])
        t += gap_before
        continue
    label = seg.get("label", "")
    dur   = float(seg["duration"])
    beats.append((label, t, t + dur, gap_before, 0.0))
    t += dur
    gap_before = 0.0
final_t = t

# ── Probe V2 sources for clip durations ──────────────────────────────────────
def ffprobe_dur(path):
    if not os.path.isfile(path):
        sys.exit(f"Error: V2 source not found: {path}")
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", path]
    ).decode().strip()
    try:
        return float(out)
    except ValueError:
        sys.exit(f"Error: ffprobe couldn't read duration for {path}")

unique_v2_sources = set()
for plan in v2_plan:
    if not isinstance(plan, list):
        sys.exit(f"Error: each v2_plan entry must be a list of shots; got {type(plan).__name__}")
    for shot in plan:
        if not isinstance(shot, dict) or "source" not in shot:
            sys.exit(f"Error: every v2_plan shot needs a 'source': {shot}")
        unique_v2_sources.add(shot["source"])

src_dur = {p: ffprobe_dur(p) for p in unique_v2_sources}

# ── Distribute span across a beat's shots ────────────────────────────────────
def distribute(plan, span):
    n = len(plan)
    caps = []
    for shot in plan:
        s_dur = src_dur[shot["source"]]
        sin = float(shot.get("source_in", 0.0))
        cap = s_dur - sin - V2_CLR
        if cap < 0.05:
            return None, (
                f"shot {os.path.basename(shot['source'])} src_in={sin:.2f}s leaves only "
                f"{cap:.2f}s of usable footage (source is {s_dur:.2f}s, clearance {V2_CLR:.2f}s). "
                f"Lower source_in or pick a longer source."
            )
        caps.append(cap)
    sum_caps = sum(caps)
    if sum_caps + 0.01 < span:
        deficit = span - sum_caps
        names = ", ".join(os.path.basename(s["source"]) for s in plan)
        return None, (
            f"source budget {sum_caps:.2f}s < beat span {span:.2f}s "
            f"(deficit {deficit:.2f}s). Shots: {names}. Add more shots, or pick "
            f"segments with smaller source_in."
        )
    durs = [0.0] * n
    remaining = span
    active = list(range(n))
    while remaining > 0.01 and active:
        share = remaining / len(active)
        new_active = []
        for j in active:
            take = min(share, caps[j] - durs[j])
            durs[j] += take
            remaining -= take
            if caps[j] - durs[j] > 0.01:
                new_active.append(j)
        if new_active == active:
            break
        active = new_active
    return durs, None

# ── Build V2 ─────────────────────────────────────────────────────────────────
v2_out = []
warnings = []
errors  = []

for i, (label, t_start, t_end, gap_before, gap_after) in enumerate(beats):
    plan = v2_plan[i]
    if not plan:
        warnings.append(f"Beat {i+1} ({label}): empty plan — V2 leaves {t_end-t_start:.2f}s "
                        f"of black over this beat.")
        continue

    if i == 0:
        v2_start = V2_HEAD
    else:
        v2_start = beats[i-1][2] + beats[i-1][4] / 2.0   # prev t_end + gap_after/2

    if i == len(beats) - 1:
        v2_end = t_end - V2_TAIL
    else:
        v2_end = t_end + gap_after / 2.0

    span = round(v2_end - v2_start, 4)
    if span <= 0:
        errors.append(f"Beat {i+1} ({label}): non-positive V2 span ({span:.2f}s) — "
                      f"v2_head_show ({V2_HEAD}) too long, or beat too short.")
        continue

    durs, err = distribute(plan, span)
    if err is not None:
        errors.append(f"Beat {i+1} ({label}): {err}")
        continue

    cur = v2_start
    for shot, dur in zip(plan, durs):
        if dur < 0.05:
            continue
        out = {
            "timeline_start": round(cur, 3),
            "duration":       round(dur, 3),
            "source":         shot["source"],
            "source_in":      float(shot.get("source_in", 0.0)),
        }
        if "label" in shot:
            out["label"] = f"Beat {i+1} - {shot['label']}"
        v2_out.append(out)
        cur = round(cur + dur, 3)

if errors:
    print(f"bridge_broll: {len(errors)} error(s) — no output written.\n", file=sys.stderr)
    for e in errors:
        print(f"  {e}", file=sys.stderr)
    sys.exit(1)

# ── Verify V2 contiguity (sanity check) ──────────────────────────────────────
prev_end = V2_HEAD
gap_count = 0
for v in v2_out:
    if abs(v["timeline_start"] - prev_end) > 0.02:
        gap_count += 1
    prev_end = round(v["timeline_start"] + v["duration"], 3)

# ── Assemble output ──────────────────────────────────────────────────────────
out_obj = {k: v for k, v in raw.items() if k not in ("v2_plan", "bridge_broll_options")}
out_obj.setdefault("tracks", {})
out_obj["tracks"]["V1"] = v1_padded
out_obj["tracks"]["V2"] = v2_out

out_text = json.dumps(out_obj, indent=2)

if output_path == "-":
    sys.stdout.write(out_text + "\n")
else:
    if os.path.exists(output_path):
        print(f"bridge_broll: overwriting existing {output_path}", file=sys.stderr)
    with open(output_path, "w") as f:
        f.write(out_text + "\n")
    print(f"bridge_broll: wrote {output_path}", file=sys.stderr)

# ── Diagnostic summary on stderr ─────────────────────────────────────────────
total_v2 = sum(v["duration"] for v in v2_out)
print(
    f"bridge_broll: padded {sum(1 for s in v1 if 'gap' not in s)} V1 cuts "
    f"(+{V1_LEAD:.2f}s lead, +{V1_TRAIL:.2f}s trail); "
    f"emitted {len(v2_out)} V2 shots covering {total_v2:.2f}s of {final_t:.2f}s timeline "
    f"({100*total_v2/final_t:.0f}%)",
    file=sys.stderr,
)
if gap_count:
    print(f"warning: {gap_count} non-contiguous V2 transitions detected (>20ms drift)",
          file=sys.stderr)
for w in warnings:
    print(f"  {w}", file=sys.stderr)
PYEOF
