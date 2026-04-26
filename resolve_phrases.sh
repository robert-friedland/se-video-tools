#!/bin/bash
# resolve_phrases — pre-process a phrase-based JSON cut list into a time-based
# JSON cut list ready for build_timeline. Reads <source>.transcript.words.json
# next to each source, finds the verbatim phrase, and emits exact word-level
# start/duration.
#
# Usage: resolve_phrases [--window SECONDS] <input.json> [output.json]
#        resolve_phrases update
#
# Options:
#   --window SECONDS  Default near-window (half-window, ±SECONDS) when a
#                     segment doesn't specify its own. Default 10.
#   -h, --help        Show this help.
#
# Input shapes (same as build_timeline):
#
#   Bare list (V1 only):
#     [
#       {"source": "/abs/path.mp4", "phrase": "exact words", "near": 245.6, "label": "Beat 1"},
#       {"gap": 0.6},
#       {"source": "/abs/path2.mp4", "start": 234.84, "duration": 10.16}
#     ]
#
#   Object with segments:
#     {"name": "My Cut", "segments": [ ... ]}
#
#   Multi-track:
#     {"name": "...", "tracks": {"V1": [...], "V2": [...]}}
#
# Phrase-based segment fields:
#   source   absolute path to a source MP4/MOV with a sibling .transcript.words.json
#   phrase   verbatim text from .transcript.sentences.json (single-space separated tokens)
#   near     approximate timestamp; the start time of the first sentence the phrase touches
#   window   optional per-segment override of --window (half-window, ±seconds)
#   label    optional, passes through
#
# Time-based segments (start/duration, timeline_start/source_in, gap) and any
# unknown fields pass through byte-identical. Phrase resolution is per-segment;
# tracks are not inspected by the resolver.
#
# Errors are collected across all segments; the tool exits non-zero only after
# walking everything.

set -e

# Resolve real script location through symlinks
SCRIPT_DIR="$(cd "$(dirname "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")" && pwd)"

GITHUB_RAW_BASE="https://raw.githubusercontent.com/robert-friedland/se-video-tools/main"

# ── Update subcommand ────────────────────────────────────────────────────────
if [ "${1:-}" = "update" ]; then
    echo "Updating resolve_phrases..."
    curl -fsSL "${GITHUB_RAW_BASE}/resolve_phrases.sh" -o "$SCRIPT_DIR/resolve_phrases.sh.tmp" \
        && mv "$SCRIPT_DIR/resolve_phrases.sh.tmp" "$SCRIPT_DIR/resolve_phrases.sh" \
        && chmod +x "$SCRIPT_DIR/resolve_phrases.sh"
    if [ -d "$HOME/.claude/commands" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/commands/resolve-phrases.md" \
            -o "$HOME/.claude/commands/resolve-phrases.md"
        echo "Claude skill updated."
    fi
    echo "Done."
    exit 0
fi

usage() {
    sed -n '2,42p' "$SCRIPT_DIR/resolve_phrases.sh" | sed 's/^# \{0,1\}//'
}

# ── Argument parsing ─────────────────────────────────────────────────────────
WINDOW="10.0"
POSITIONALS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --window) WINDOW="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --*)      echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)        POSITIONALS+=("$1"); shift ;;
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
        # foo.json → foo.resolved.json (output is still JSON; infix keeps both visible)
        STEM="${INPUT%.*}"
        if [ "$STEM" = "$INPUT" ]; then
            OUTPUT="${INPUT}.resolved.json"
        else
            OUTPUT="${STEM}.resolved.json"
        fi
    fi
fi

# Dependency checks
command -v python3 >/dev/null || { echo "Error: python3 not found" >&2; exit 1; }

# Buffer stdin to a tempfile so the python heredoc doesn't consume it
_STDIN_TMP=""
if [ "$INPUT" = "-" ]; then
    _STDIN_TMP=$(mktemp /tmp/resolve_phrases_stdin_XXXXXX.json)
    cat > "$_STDIN_TMP"
    INPUT="$_STDIN_TMP"
    trap 'rm -f "$_STDIN_TMP"' EXIT INT TERM
fi

# ── Resolution via Python ────────────────────────────────────────────────────
python3 - "$INPUT" "$OUTPUT" "$WINDOW" <<'PYEOF'
import sys, json, os, hashlib

input_path, output_path, default_window_str = sys.argv[1:]
default_window = float(default_window_str)

with open(input_path) as f:
    raw = json.load(f)

# ── Normalize input shape into tracks_in: ordered dict[str, list] ────────────
# Track keys preserved as-is (V1, V2, etc.) so output mirrors input.
shape = None  # "list" | "segments" | "tracks"
top_meta = {}  # everything in raw besides segments/tracks
tracks_in = {}

if isinstance(raw, list):
    shape = "list"
    tracks_in["__only__"] = raw
elif isinstance(raw, dict):
    if "segments" in raw and "tracks" in raw:
        sys.exit("Error: top-level JSON has both 'segments' and 'tracks'; specify only one.")
    if "tracks" in raw:
        shape = "tracks"
        if not isinstance(raw["tracks"], dict):
            sys.exit("Error: 'tracks' must be an object mapping track keys to segment lists.")
        for k, v in raw["tracks"].items():
            tracks_in[k] = v
        top_meta = {k: v for k, v in raw.items() if k != "tracks"}
    elif "segments" in raw:
        shape = "segments"
        tracks_in["__only__"] = raw["segments"]
        top_meta = {k: v for k, v in raw.items() if k != "segments"}
    else:
        sys.exit("Error: top-level object must contain 'segments' or 'tracks'.")
else:
    sys.exit("Error: top-level JSON must be an array or an object.")

# ── Cache for words.json files (path → (words list, hash)) ───────────────────
_cache = {}
def load_words(source_path):
    if source_path in _cache:
        return _cache[source_path]
    stem, _ = os.path.splitext(source_path)
    words_path = stem + ".transcript.words.json"
    if not os.path.isfile(words_path):
        raise FileNotFoundError(words_path)
    with open(words_path, "rb") as f:
        raw_bytes = f.read()
    h = hashlib.sha256(raw_bytes).hexdigest()[:16]
    words = json.loads(raw_bytes)
    _cache[source_path] = (words, h, words_path)
    return _cache[source_path]

# ── Per-segment validation and resolution ────────────────────────────────────
errors = []  # collected error strings; non-empty → exit non-zero

TIME_FIELDS = {"start", "duration", "timeline_start", "source_in"}

def validate_phrase_segment(seg):
    """Returns None if valid, else an error string."""
    has_phrase = "phrase" in seg
    has_near = "near" in seg
    has_window = "window" in seg
    has_time = bool(TIME_FIELDS & set(seg.keys()))
    has_gap = "gap" in seg

    if has_phrase:
        if not isinstance(seg["phrase"], str) or not seg["phrase"].strip():
            return "phrase is empty or not a string"
        if not has_near:
            return "phrase requires near"
        if has_time:
            return "phrase is mutually exclusive with start/duration/timeline_start/source_in"
        if not isinstance(seg["near"], (int, float)):
            return "near must be a number"
        if has_window:
            w = seg["window"]
            if not isinstance(w, (int, float)) or w <= 0:
                return "window must be a positive number"
        if "source" not in seg or not seg["source"]:
            return "phrase segment missing 'source'"
    else:
        if has_near:
            return "near requires phrase (typo guard)"
        if has_window:
            return "window requires phrase (typo guard)"
        if not has_time and not has_gap:
            return "segment must have phrase, time-based fields, or gap"

    return None

def resolve_phrase(seg, default_window):
    """Returns (resolved_seg, error_str). Exactly one is non-None."""
    err = validate_phrase_segment(seg)
    if err:
        return None, err

    if "phrase" not in seg:
        # Passthrough — no audit field, byte-identical
        return seg, None

    phrase = seg["phrase"].strip()
    near = float(seg["near"])
    window = float(seg.get("window", default_window))
    source = seg["source"]

    try:
        words, words_hash, words_path = load_words(source)
    except FileNotFoundError as e:
        return None, (
            f"transcript not found at {e.args[0]}.\n"
            f"  Generate it with: transcribe {source}"
        )

    phrase_tokens = phrase.split(" ")
    if not phrase_tokens or any(t == "" for t in phrase_tokens):
        return None, f"phrase contains empty tokens (multiple consecutive spaces?): {phrase!r}"

    N = len(phrase_tokens)
    if N > len(words):
        return None, f"phrase has {N} tokens, transcript only has {len(words)} words"

    # Word-index matching: slide a window of size N over words, exact token equality
    matches = []  # list of starting word indices
    for i in range(len(words) - N + 1):
        if all(words[i + j]["word"] == phrase_tokens[j] for j in range(N)):
            matches.append(i)

    if not matches:
        # Provide a useful diagnostic: closest single-token match? Total occurrences of first token?
        first_tok_count = sum(1 for w in words if w["word"] == phrase_tokens[0])
        return None, (
            f"phrase not found in {os.path.basename(source)}: {phrase!r}\n"
            f"  (first token {phrase_tokens[0]!r} appears {first_tok_count}x in transcript; "
            f"check punctuation and exact wording from sentences.json)"
        )

    # Compute distances from near
    candidates = [(i, words[i]["start"], abs(words[i]["start"] - near)) for i in matches]
    in_window = [c for c in candidates if c[2] <= window]

    if not in_window:
        nearest = min(candidates, key=lambda c: c[2])
        return None, (
            f"phrase {phrase!r} found {len(matches)}x in {os.path.basename(source)}, "
            f"but none within near={near:.2f} ±{window:.1f}s. "
            f"Nearest at t={nearest[1]:.2f} (Δ={nearest[2]:.2f}s). "
            f"Widen --window or correct near."
        )

    # Disambiguate
    in_window.sort(key=lambda c: c[2])
    if len(in_window) > 1:
        d0 = in_window[0][2]
        d1 = in_window[1][2]
        threshold = max(0.5, min(2.0, 0.25 * d0))
        if d1 - d0 < threshold:
            cand_str = "; ".join(f"t={c[1]:.2f} (Δ={c[2]:.2f})" for c in in_window)
            return None, (
                f"ambiguous phrase {phrase!r} in {os.path.basename(source)}: "
                f"multiple matches near={near:.2f} within disambiguation threshold "
                f"({d1-d0:.2f}s gap < {threshold:.2f}s threshold). "
                f"Candidates: {cand_str}"
            )

    chosen_i = in_window[0][0]
    first = chosen_i
    last = chosen_i + N - 1
    start = words[first]["start"]
    end = words[last]["end"]
    duration = end - start

    if duration <= 0:
        return None, (
            f"resolved duration non-positive ({duration:.3f}s) for phrase {phrase!r} "
            f"in {os.path.basename(source)} at words[{first}:{last+1}] — likely transcript corruption"
        )

    out = dict(seg)
    out.pop("phrase", None)
    out.pop("near", None)
    out.pop("window", None)
    out["start"] = round(start, 3)
    out["duration"] = round(duration, 3)
    audit = {
        "phrase": phrase,
        "near": near,
        "anchor": round(start, 3),
        "words_hash": words_hash,
    }
    if "window" in seg:
        audit["window"] = window
    out["_resolve_phrases"] = audit
    return out, None

# ── Walk all tracks, resolve, collect errors ─────────────────────────────────
def fmt_loc(track_key, idx):
    if track_key == "__only__":
        return f"#{idx+1}"
    return f"[{track_key}#{idx+1}]"

resolved_tracks = {}
diff_lines = []  # printed to stderr on success

for track_key, segs in tracks_in.items():
    if not isinstance(segs, list):
        errors.append(f"{fmt_loc(track_key, -1)} track is not a list")
        continue
    out_segs = []
    for idx, seg in enumerate(segs):
        if not isinstance(seg, dict):
            errors.append(f"{fmt_loc(track_key, idx)} segment is not an object")
            continue
        resolved, err = resolve_phrase(seg, default_window)
        if err:
            errors.append(f"{fmt_loc(track_key, idx)} {err}")
            continue
        out_segs.append(resolved)
        if "_resolve_phrases" in resolved:
            audit = resolved["_resolve_phrases"]
            phrase_short = audit["phrase"]
            if len(phrase_short) > 50:
                phrase_short = phrase_short[:47] + "..."
            src_base = os.path.basename(resolved["source"])
            dstart = resolved["start"] - audit["near"]
            diff_lines.append(
                f"{fmt_loc(track_key, idx)} {src_base}: phrase={phrase_short!r} "
                f"near={audit['near']:.2f} → start={resolved['start']:.2f} "
                f"duration={resolved['duration']:.2f}s (Δstart={dstart:+.2f})"
            )
    resolved_tracks[track_key] = out_segs

if errors:
    print(f"resolve_phrases: {len(errors)} error(s) — no output written.\n", file=sys.stderr)
    for e in errors:
        print(f"  {e}", file=sys.stderr)
    sys.exit(1)

# ── Reassemble output in input shape ─────────────────────────────────────────
if shape == "list":
    out_obj = resolved_tracks["__only__"]
elif shape == "segments":
    out_obj = dict(top_meta)
    out_obj["segments"] = resolved_tracks["__only__"]
elif shape == "tracks":
    out_obj = dict(top_meta)
    out_obj["tracks"] = {k: v for k, v in resolved_tracks.items()}
else:
    sys.exit("Internal error: unknown shape")

out_text = json.dumps(out_obj, indent=2)

if output_path == "-":
    sys.stdout.write(out_text + "\n")
else:
    if os.path.exists(output_path):
        print(f"resolve_phrases: overwriting existing {output_path}", file=sys.stderr)
    with open(output_path, "w") as f:
        f.write(out_text + "\n")
    print(f"resolve_phrases: wrote {output_path}", file=sys.stderr)

# Print diff log to stderr
for line in diff_lines:
    print(line, file=sys.stderr)
PYEOF
