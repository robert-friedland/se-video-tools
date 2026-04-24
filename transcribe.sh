#!/bin/bash
# transcribe — local Whisper transcription (whisper.cpp) with per-word and per-sentence timings.
#
# Usage: transcribe <video-or-folder> [OPTIONS]
#        transcribe update
#
# Options:
#   --model NAME_OR_PATH    Whisper model: short name (tiny.en, base.en, small.en, medium.en,
#                           large-v3, large-v3-turbo) or explicit .bin path. Default: large-v3-turbo.
#                           Models auto-download to ~/.whisper-models/ on first use.
#   --language CODE         Language hint (default: en; "auto" to detect)
#   --ext LIST              Comma-separated extensions to process in folder mode
#                           (default: mp4,mov,m4v,mkv,MP4,MOV,M4V,MKV,wav,mp3)
#   --min-words N           Threshold for likely_interview flag (default: 30)
#   --threads N             Threads for whisper-cli (default: whisper-cli's own default)
#   --force                 Overwrite existing outputs
#   --keep-wav              Keep the extracted 16kHz WAV next to the video (default: delete)
#   -h, --help              Show this help
#
# Outputs (alongside each <video>):
#   <video>.transcript.json            combined: {source, model, language, duration,
#                                                 text, words[], sentences[], summary}
#   <video>.transcript.words.json      [{word, start, end}, ...]
#   <video>.transcript.sentences.json  [{sentence, start, end, word_start, word_end}, ...]
#   <video>.transcript.words.srt       Resolve-compatible (one cue per word)
#   <video>.transcript.sentences.srt   Resolve-compatible (one cue per sentence)
#   <video>.transcript.txt             plain text
#
# Requires: whisper-cli (brew install whisper-cpp), ffmpeg, python3.

set -e

# Resolve real script location through symlinks (handles Homebrew symlinks)
SCRIPT_DIR="$(cd "$(dirname "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")" && pwd)"

GITHUB_RAW_BASE="https://raw.githubusercontent.com/robert-friedland/se-video-tools/main"
MODELS_DIR="$HOME/.whisper-models"

# ── Update subcommand ────────────────────────────────────────────────────────
if [ "${1:-}" = "update" ]; then
    echo "Updating transcribe..."
    curl -fsSL "${GITHUB_RAW_BASE}/transcribe.sh" -o "$SCRIPT_DIR/transcribe.sh.tmp" \
        && mv "$SCRIPT_DIR/transcribe.sh.tmp" "$SCRIPT_DIR/transcribe.sh" \
        && chmod +x "$SCRIPT_DIR/transcribe.sh"
    if [ -d "$HOME/.claude/commands" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/commands/transcribe.md" \
            -o "$HOME/.claude/commands/transcribe.md"
        echo "Claude skill updated."
    fi
    echo "Done."
    exit 0
fi

usage() {
    sed -n '2,35p' "$SCRIPT_DIR/transcribe.sh" | sed 's/^# \{0,1\}//'
}

# ── Defaults ─────────────────────────────────────────────────────────────────
MODEL="large-v3-turbo"
LANGUAGE="en"
EXT_LIST="mp4,mov,m4v,mkv,MP4,MOV,M4V,MKV,wav,mp3"
MIN_WORDS="30"
THREADS=""
FORCE="false"
KEEP_WAV="false"
POSITIONALS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --model)        MODEL="$2"; shift 2 ;;
        --language)     LANGUAGE="$2"; shift 2 ;;
        --ext)          EXT_LIST="$2"; shift 2 ;;
        --min-words)    MIN_WORDS="$2"; shift 2 ;;
        --threads)      THREADS="$2"; shift 2 ;;
        --force)        FORCE="true"; shift ;;
        --keep-wav)   KEEP_WAV="true"; shift ;;
        -h|--help)      usage; exit 0 ;;
        --*)            echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)              POSITIONALS+=("$1"); shift ;;
    esac
done

if [ "${#POSITIONALS[@]}" -ne 1 ]; then
    echo "Error: expected exactly one <video-or-folder> argument" >&2
    usage >&2
    exit 1
fi
TARGET="${POSITIONALS[0]}"

# ── Dependency checks ────────────────────────────────────────────────────────
command -v whisper-cli >/dev/null || {
    echo "Error: whisper-cli not found." >&2
    echo "Install with: brew install whisper-cpp" >&2
    exit 1
}
command -v ffmpeg  >/dev/null || { echo "Error: ffmpeg not found"  >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "Error: ffprobe not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "Error: python3 not found" >&2; exit 1; }
command -v curl    >/dev/null || { echo "Error: curl not found"    >&2; exit 1; }

# ── Resolve model → path (auto-download if short name) ───────────────────────
resolve_model() {
    local m="$1"
    # Already a file path?
    if [ -f "$m" ]; then
        echo "$m"
        return 0
    fi
    # Treat as short name → ggml-<name>.bin under MODELS_DIR
    local fname="ggml-${m}.bin"
    local path="$MODELS_DIR/$fname"
    if [ -f "$path" ]; then
        echo "$path"
        return 0
    fi
    # Download
    mkdir -p "$MODELS_DIR"
    local url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${fname}"
    echo "Downloading model $fname..." >&2
    if ! curl -fL --progress-bar "$url" -o "$path.tmp"; then
        rm -f "$path.tmp"
        echo "Error: model download failed. Known short names: tiny.en, base.en, small.en, medium.en, large-v3, large-v3-turbo." >&2
        exit 1
    fi
    mv "$path.tmp" "$path"
    echo "$path"
}

MODEL_PATH=$(resolve_model "$MODEL")
echo "Using model: $MODEL_PATH"

# ── Build file list ──────────────────────────────────────────────────────────
FILES=()
if [ -f "$TARGET" ]; then
    FILES=("$TARGET")
elif [ -d "$TARGET" ]; then
    # Non-recursive; match any of the configured extensions
    IFS=',' read -r -a EXTS <<< "$EXT_LIST"
    for ext in "${EXTS[@]}"; do
        while IFS= read -r -d '' f; do
            FILES+=("$f")
        done < <(find "$TARGET" -maxdepth 1 -type f -name "*.${ext}" -print0)
    done
    if [ "${#FILES[@]}" -eq 0 ]; then
        echo "No files matching *.{${EXT_LIST}} under: $TARGET" >&2
        exit 1
    fi
else
    echo "Error: not a file or directory: $TARGET" >&2
    exit 1
fi

echo "Found ${#FILES[@]} file(s) to process."
echo ""

# ── Per-file processor ───────────────────────────────────────────────────────
# Writes one JSON row per processed file to $SUMMARY_TSV for end-of-run table.
SUMMARY_TSV=$(mktemp /tmp/transcribe_sum_XXXXXX)
trap 'rm -f "$SUMMARY_TSV"' EXIT INT TERM

process_one() {
    local video="$1"
    local base="${video%.*}"
    local outJson="${base}.transcript.json"
    local outWordsJson="${base}.transcript.words.json"
    local outSentsJson="${base}.transcript.sentences.json"
    local outWordsSrt="${base}.transcript.words.srt"
    local outSentsSrt="${base}.transcript.sentences.srt"
    local outTxt="${base}.transcript.txt"

    # Skip if all outputs exist (unless --force)
    if [ "$FORCE" != "true" ] \
       && [ -f "$outJson" ] && [ -f "$outWordsJson" ] && [ -f "$outSentsJson" ] \
       && [ -f "$outWordsSrt" ] && [ -f "$outSentsSrt" ] && [ -f "$outTxt" ]; then
        echo "↷ $video (all outputs exist — use --force to regenerate)"
        # Still emit summary row from existing JSON so the final table is complete
        python3 - "$outJson" "$video" "$SUMMARY_TSV" <<'PYEOF'
import json, sys
p, src, tsv = sys.argv[1:]
try:
    d = json.load(open(p))
    s = d.get("summary", {})
    with open(tsv, "a") as f:
        f.write("\t".join(str(x) for x in [
            src,
            s.get("word_count", 0),
            f"{s.get('speech_seconds', 0):.1f}",
            f"{s.get('duration_seconds', 0):.1f}",
            f"{s.get('speech_ratio', 0):.2f}",
            "yes" if s.get("likely_interview") else "no",
        ]) + "\n")
except Exception:
    pass
PYEOF
        return 0
    fi

    echo "→ $video"

    # ── Extract 16kHz mono WAV next to video (easy to keep with --keep-wav) ──
    local wav="${base}.transcribe.wav"
    if ! ffmpeg -y -i "$video" -ar 16000 -ac 1 -vn "$wav" </dev/null >/dev/null 2>&1; then
        echo "  ffmpeg extraction failed; skipping" >&2
        return 1
    fi

    # ── Probe source duration (seconds, float) ───────────────────────────────
    local duration
    duration=$(ffprobe -v error -select_streams a:0 -show_entries format=duration -of default=nk=1:nw=1 "$video" 2>/dev/null || echo "0")
    [ -z "$duration" ] && duration="0"

    # ── Run whisper-cli ──────────────────────────────────────────────────────
    local whisper_base="${base}.transcribe"   # whisper-cli adds its own extensions
    local threads_args=()
    [ -n "$THREADS" ] && threads_args=(-t "$THREADS")

    # -oj     JSON output
    # -ml 1   one segment per word
    # -sow    split on word boundary (not sub-word token)
    # -of     output basename (no extension)
    # -np     quiet: don't print segments as they come in (we'll show our own progress)
    if ! whisper-cli \
            -m "$MODEL_PATH" \
            -l "$LANGUAGE" \
            -f "$wav" \
            -oj -ml 1 -sow \
            -of "$whisper_base" \
            -np \
            "${threads_args[@]}" >/dev/null 2>"${wav}.log"; then
        echo "  whisper-cli failed (see ${wav}.log); skipping" >&2
        [ "$KEEP_WAV" = "true" ] || rm -f "$wav"
        return 1
    fi

    # whisper-cli writes ${whisper_base}.json
    local raw_json="${whisper_base}.json"
    if [ ! -f "$raw_json" ]; then
        echo "  whisper-cli produced no JSON; skipping" >&2
        [ "$KEEP_WAV" = "true" ] || rm -f "$wav"
        return 1
    fi

    # ── Post-process into our output set ─────────────────────────────────────
    python3 - "$raw_json" "$video" "$MODEL_PATH" "$LANGUAGE" "$duration" \
               "$outJson" "$outWordsJson" "$outSentsJson" \
               "$outWordsSrt" "$outSentsSrt" "$outTxt" \
               "$MIN_WORDS" "$SUMMARY_TSV" <<'PYEOF'
import sys, json, re, os

(raw_path, source, model_path, language, duration_s,
 out_json, out_words_json, out_sents_json,
 out_words_srt, out_sents_srt, out_txt,
 min_words_s, summary_tsv) = sys.argv[1:]

duration = float(duration_s) if duration_s else 0.0
min_words = int(min_words_s)

with open(raw_path) as f:
    raw = json.load(f)

entries = raw.get("transcription", [])

# ── Build word list ──────────────────────────────────────────────────────────
# whisper.cpp with `-ml 1 -sow` emits one entry per word. Non-speech markers
# come through as bracketed tokens like `[BLANK_AUDIO]`, `[Music]`, `[Applause]`.
# Those are useful as presence signals but are NOT real speech for the classifier.
BRACKETED = re.compile(r'^\[.*\]$')

words = []
all_tokens = []   # includes brackets — used for raw .txt dump
for e in entries:
    raw_text = e.get("text", "")
    stripped = raw_text.strip()
    if not stripped:
        continue
    start_ms = e.get("offsets", {}).get("from")
    end_ms   = e.get("offsets", {}).get("to")
    if start_ms is None or end_ms is None:
        continue
    start = start_ms / 1000.0
    end   = end_ms / 1000.0
    all_tokens.append({"word": stripped, "start": start, "end": end, "bracketed": bool(BRACKETED.match(stripped))})
    if BRACKETED.match(stripped):
        continue
    words.append({"word": stripped, "start": start, "end": end})

# ── Sentence grouping (same heuristic as elevenlabs_tts.sh) ──────────────────
STOP_LIST = {
    "Dr", "Mr", "Mrs", "Ms", "Prof", "Jr", "Sr", "St", "Ave", "Rd", "Blvd",
    "Inc", "Ltd", "Co", "Corp", "vs", "etc", "eg", "ie", "cf", "approx",
}
CLOSING_PUNCT = '"\'*)}]>”’'

def is_terminator_tail(w):
    s = w.rstrip(CLOSING_PUNCT)
    return bool(s) and s[-1] in ".!?…"

def body_no_terminator(w):
    s = w.rstrip(CLOSING_PUNCT)
    return s.rstrip(".!?…")

def next_starts_sentence(next_word):
    s = next_word.lstrip('"\'([{‘“')
    if not s:
        return False
    return s[0].isupper() or s[0].isdigit()

sentences = []
cur_start = 0
wi = 0
while wi < len(words):
    w = words[wi]
    is_last = (wi == len(words) - 1)
    term = is_terminator_tail(w["word"])
    if term and body_no_terminator(w["word"]) in STOP_LIST:
        wi += 1
        continue
    if is_last or (term and next_starts_sentence(words[wi + 1]["word"])):
        sent_words = words[cur_start:wi + 1]
        if sent_words:
            sentences.append({
                "sentence": " ".join(x["word"] for x in sent_words),
                "start": sent_words[0]["start"],
                "end":   sent_words[-1]["end"],
                "word_start": cur_start,
                "word_end":   wi,
            })
        cur_start = wi + 1
    wi += 1

# ── Plain text (falls back to including bracketed markers if no real words) ──
if words:
    full_text = " ".join(w["word"] for w in words)
else:
    full_text = " ".join(t["word"] for t in all_tokens)

# ── Classifier: likely_interview? ────────────────────────────────────────────
speech_seconds = sum(w["end"] - w["start"] for w in words)
speech_ratio = (speech_seconds / duration) if duration > 0 else 0.0
likely_interview = (len(words) >= min_words) and (speech_ratio >= 0.15 or duration == 0)

summary = {
    "word_count": len(words),
    "speech_seconds": round(speech_seconds, 2),
    "duration_seconds": round(duration, 2),
    "speech_ratio": round(speech_ratio, 3),
    "likely_interview": likely_interview,
}

# ── Write combined JSON ──────────────────────────────────────────────────────
combined = {
    "source": source,
    "model": os.path.basename(model_path),
    "language": language,
    "duration": duration,
    "text": full_text,
    "words": words,
    "sentences": sentences,
    "summary": summary,
}
with open(out_json, "w") as f:
    json.dump(combined, f, indent=2)

# ── Write split JSONs (top-level arrays) ─────────────────────────────────────
with open(out_words_json, "w") as f:
    json.dump(words, f, indent=2)
with open(out_sents_json, "w") as f:
    json.dump(sentences, f, indent=2)

# ── Write plain text ─────────────────────────────────────────────────────────
# Sentence-per-line when available; otherwise the full token stream.
with open(out_txt, "w") as f:
    if sentences:
        for s in sentences:
            f.write(s["sentence"] + "\n")
    else:
        f.write(full_text + ("\n" if full_text else ""))

# ── SRT writers ──────────────────────────────────────────────────────────────
def fmt_srt_time(t):
    if t < 0: t = 0
    h = int(t // 3600); t -= h * 3600
    m = int(t // 60);   t -= m * 60
    s = int(t);         ms = int(round((t - s) * 1000))
    if ms == 1000:
        s += 1; ms = 0
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

def write_srt(path, entries, text_key):
    with open(path, "w") as f:
        for i, e in enumerate(entries, 1):
            start = e["start"]
            end = max(e["end"], start + 0.001)
            f.write(f"{i}\n{fmt_srt_time(start)} --> {fmt_srt_time(end)}\n{e[text_key]}\n\n")

write_srt(out_words_srt, words, "word")
write_srt(out_sents_srt, sentences, "sentence")

# ── Append summary row ───────────────────────────────────────────────────────
with open(summary_tsv, "a") as f:
    f.write("\t".join(str(x) for x in [
        source,
        summary["word_count"],
        f"{summary['speech_seconds']:.1f}",
        f"{summary['duration_seconds']:.1f}",
        f"{summary['speech_ratio']:.2f}",
        "yes" if summary["likely_interview"] else "no",
    ]) + "\n")

# ── Per-file report ──────────────────────────────────────────────────────────
tag = "interview" if summary["likely_interview"] else "not-interview"
print(f"  {summary['word_count']} words, {summary['speech_seconds']:.1f}s speech / {summary['duration_seconds']:.1f}s ({summary['speech_ratio']:.2f}) → {tag}")
print(f"  → {out_json}")
PYEOF

    # ── Cleanup temp wav + raw json + log ────────────────────────────────────
    rm -f "$raw_json" "${wav}.log"
    if [ "$KEEP_WAV" != "true" ]; then
        rm -f "$wav"
    fi
}

# ── Main loop ────────────────────────────────────────────────────────────────
FAILED=0
for f in "${FILES[@]}"; do
    if ! process_one "$f"; then
        FAILED=$((FAILED + 1))
    fi
done

# ── Final summary table ──────────────────────────────────────────────────────
if [ -s "$SUMMARY_TSV" ]; then
    echo ""
    echo "Summary:"
    python3 - "$SUMMARY_TSV" <<'PYEOF'
import sys
rows = []
with open(sys.argv[1]) as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 6:
            rows.append(parts)
if not rows:
    sys.exit(0)
headers = ["file", "words", "speech(s)", "dur(s)", "ratio", "interview?"]
widths = [max(len(h), max((len(r[i]) for r in rows), default=0)) for i, h in enumerate(headers)]
def row(r): return "  ".join(r[i].ljust(widths[i]) for i in range(len(headers)))
print(row(headers))
print(row(["-" * w for w in widths]))
for r in rows:
    # Shorten file path to basename for readability
    import os
    r = list(r)
    r[0] = os.path.basename(r[0])
    print(row(r))
PYEOF
fi

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "$FAILED file(s) failed." >&2
    exit 1
fi
