#!/bin/bash
# elevenlabs_tts — ElevenLabs TTS with per-character, per-word, and per-sentence timings.
#
# Usage: elevenlabs_tts [OPTIONS] "text to speak"
#        elevenlabs_tts [OPTIONS] --text-file path.txt
#        elevenlabs_tts --list-voices
#        elevenlabs_tts update
#
# Options:
#   --voice NAME_OR_ID    Voice name from built-in map (Chris, Rachel, ...) or 20-char ID (default: Chris)
#   --model ID            Model ID (default: eleven_multilingual_v2)
#   --stability 0..1      voice_settings.stability (default: 0.5)
#   --similarity 0..1     voice_settings.similarity_boost (default: 0.75)
#   --style 0..1          voice_settings.style (default: 0.0)
#   --speed 0.7..1.2      voice_settings.speed (default: 1.0)
#   --no-speaker-boost    Disable voice_settings.use_speaker_boost
#   --format FMT          Output audio format (default: mp3_44100_128)
#   --text-file PATH      Read text from file (mutually exclusive with positional)
#   --out PREFIX          Output basename (default: derived from text)
#   --audio-only          Write only .mp3, skip .json + .srt
#   --force               Overwrite existing files
#   --list-voices         Print name→ID map and exit
#
# Outputs (under $PREFIX):
#   $PREFIX.mp3             audio
#   $PREFIX.json            {text, voice, voice_id, model, audio_file, characters, words, sentences, quota}
#   $PREFIX.words.srt       one cue per word (Resolve-compatible)
#   $PREFIX.sentences.srt   one cue per sentence (Resolve-compatible)
#
# Requires: ELEVENLABS_API_KEY env var (free tier, TTS-only is fine).

set -e

# Resolve real script location through symlinks (handles Homebrew symlinks)
SCRIPT_DIR="$(cd "$(dirname "$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "${BASH_SOURCE[0]}")")" && pwd)"

GITHUB_RAW_BASE="https://raw.githubusercontent.com/robert-friedland/se-video-tools/main"

# ── Update subcommand ─────────────────────────────────────────────────────────
if [ "${1:-}" = "update" ]; then
    echo "Updating elevenlabs_tts..."
    curl -fsSL "${GITHUB_RAW_BASE}/elevenlabs_tts.sh" -o "$SCRIPT_DIR/elevenlabs_tts.sh.tmp" \
        && mv "$SCRIPT_DIR/elevenlabs_tts.sh.tmp" "$SCRIPT_DIR/elevenlabs_tts.sh" \
        && chmod +x "$SCRIPT_DIR/elevenlabs_tts.sh"
    if [ -d "$HOME/.claude/commands" ]; then
        curl -fsSL "${GITHUB_RAW_BASE}/commands/elevenlabs-tts.md" \
            -o "$HOME/.claude/commands/elevenlabs-tts.md"
        echo "Claude skill updated."
    fi
    echo "Done."
    exit 0
fi

# ── Built-in voice name → ID map (bash 3.2-compatible; no associative array) ──
lookup_voice_id() {
    case "$1" in
        chris)   echo "iP95p4xoKVk53GoZ742B" ;;
        rachel)  echo "21m00Tcm4TlvDq8ikWAM" ;;
        adam)    echo "pNInz6obpgDQGcFmaJgB" ;;
        antoni)  echo "ErXwobaYiN019PkySvjV" ;;
        bella)   echo "EXAVITQu4vr4xnSDxMAC" ;;
        elli)    echo "MF3mGyEYCl7XYWbV9V6O" ;;
        josh)    echo "TxGEqnHWrfWFTfGW9XjX" ;;
        sam)     echo "yoZ06aMxZJJ28mfd3POQ" ;;
        domi)    echo "AZnzlk1HvdDE1D1po2AQ" ;;
        *)       return 1 ;;
    esac
}

list_voices() {
    cat <<'EOF'
  chris      iP95p4xoKVk53GoZ742B
  rachel     21m00Tcm4TlvDq8ikWAM
  adam       pNInz6obpgDQGcFmaJgB
  antoni     ErXwobaYiN019PkySvjV
  bella      EXAVITQu4vr4xnSDxMAC
  elli       MF3mGyEYCl7XYWbV9V6O
  josh       TxGEqnHWrfWFTfGW9XjX
  sam        yoZ06aMxZJJ28mfd3POQ
  domi       AZnzlk1HvdDE1D1po2AQ
EOF
}

usage() {
    cat >&2 <<'EOF'
Usage: elevenlabs_tts [OPTIONS] "text"
       elevenlabs_tts [OPTIONS] --text-file PATH
       elevenlabs_tts --list-voices
       elevenlabs_tts update

Common options: --voice NAME_OR_ID  --out PREFIX  --audio-only  --force
See the top of elevenlabs_tts.sh for the full option list.
EOF
}

# ── Defaults ──────────────────────────────────────────────────────────────────
VOICE="Chris"
MODEL="eleven_multilingual_v2"
STABILITY="0.5"
SIMILARITY="0.75"
STYLE="0.0"
SPEED="1.0"
SPEAKER_BOOST="true"
FORMAT="mp3_44100_128"
TEXT_FILE=""
OUT_PREFIX=""
AUDIO_ONLY="false"
FORCE="false"
POSITIONALS=()

# ── Parse args ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --voice)             VOICE="$2"; shift 2 ;;
        --model)             MODEL="$2"; shift 2 ;;
        --stability)         STABILITY="$2"; shift 2 ;;
        --similarity)        SIMILARITY="$2"; shift 2 ;;
        --style)             STYLE="$2"; shift 2 ;;
        --speed)             SPEED="$2"; shift 2 ;;
        --no-speaker-boost)  SPEAKER_BOOST="false"; shift ;;
        --format)            FORMAT="$2"; shift 2 ;;
        --text-file)         TEXT_FILE="$2"; shift 2 ;;
        --out|--output)      OUT_PREFIX="$2"; shift 2 ;;
        --audio-only)        AUDIO_ONLY="true"; shift ;;
        --force)             FORCE="true"; shift ;;
        --list-voices)       list_voices; exit 0 ;;
        -h|--help)           usage; exit 0 ;;
        --*)                 echo "Unknown option: $1" >&2; usage; exit 1 ;;
        *)                   POSITIONALS+=("$1"); shift ;;
    esac
done

# ── Dependency checks ─────────────────────────────────────────────────────────
command -v curl    >/dev/null || { echo "Error: curl not found"    >&2; exit 1; }
command -v python3 >/dev/null || { echo "Error: python3 not found" >&2; exit 1; }

# ── Validate API key ──────────────────────────────────────────────────────────
if [ -z "${ELEVENLABS_API_KEY:-}" ]; then
    echo "Error: ELEVENLABS_API_KEY is not set" >&2
    echo "Export it: export ELEVENLABS_API_KEY=sk_..." >&2
    exit 1
fi

# ── Resolve text source ───────────────────────────────────────────────────────
if [ -n "$TEXT_FILE" ] && [ "${#POSITIONALS[@]}" -gt 0 ]; then
    echo "Error: --text-file and positional text are mutually exclusive" >&2
    exit 1
fi

if [ -n "$TEXT_FILE" ]; then
    [ -f "$TEXT_FILE" ] || { echo "Error: text file not found: $TEXT_FILE" >&2; exit 1; }
    [ -r "$TEXT_FILE" ] || { echo "Error: text file not readable: $TEXT_FILE" >&2; exit 1; }
    TEXT=$(cat "$TEXT_FILE")
elif [ "${#POSITIONALS[@]}" -gt 0 ]; then
    TEXT="${POSITIONALS[0]}"
else
    echo "Error: no text provided" >&2
    usage
    exit 1
fi

# Reject empty / whitespace-only text
if [ -z "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ]; then
    echo "Error: text is empty or whitespace-only" >&2
    exit 1
fi

# ── Resolve voice name → voice_id ─────────────────────────────────────────────
VOICE_LOWER=$(echo "$VOICE" | tr '[:upper:]' '[:lower:]')
if VOICE_ID=$(lookup_voice_id "$VOICE_LOWER"); then
    :
elif [[ "$VOICE" =~ ^[A-Za-z0-9]{20}$ ]]; then
    VOICE_ID="$VOICE"
else
    echo "Error: unknown voice '$VOICE'" >&2
    echo "Built-in names:" >&2
    list_voices >&2
    echo "Or pass a raw 20-char voice_id." >&2
    exit 1
fi

# ── Clamp --speed to API-allowed range ────────────────────────────────────────
SPEED=$(python3 -c "s=float('$SPEED'); print(max(0.7, min(1.2, s)))")

# ── Resolve output prefix ─────────────────────────────────────────────────────
# Target file set depends on --audio-only.
target_files_for() {
    local p="$1"
    if [ "$AUDIO_ONLY" = "true" ]; then
        echo "$p.mp3"
    else
        echo "$p.mp3 $p.json $p.words.json $p.sentences.json $p.words.srt $p.sentences.srt"
    fi
}

any_exist() {
    for f in "$@"; do
        [ -e "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

if [ -z "$OUT_PREFIX" ]; then
    # Derive from first 40 chars of text
    BASE_PREFIX=$(python3 -c "
import sys, re
t = sys.argv[1][:40].lower()
t = re.sub(r'[^a-z0-9]+', '_', t).strip('_')
print(t or 'elevenlabs_tts_output')
" "$TEXT")

    if [ "$FORCE" = "true" ]; then
        # --force without --out: clobber base
        OUT_PREFIX="$BASE_PREFIX"
    else
        # Auto-suffix if base collides with any current-invocation file
        OUT_PREFIX="$BASE_PREFIX"
        # shellcheck disable=SC2086
        if any_exist $(target_files_for "$OUT_PREFIX") >/dev/null; then
            FOUND=""
            for i in $(seq 1 999); do
                CANDIDATE="${BASE_PREFIX}_${i}"
                # shellcheck disable=SC2086
                if ! any_exist $(target_files_for "$CANDIDATE") >/dev/null; then
                    OUT_PREFIX="$CANDIDATE"
                    FOUND="1"
                    break
                fi
            done
            [ -z "$FOUND" ] && {
                echo "Error: no free suffix under ${BASE_PREFIX}_999; use --out PREFIX" >&2
                exit 1
            }
        fi
    fi
    echo "Using prefix: $OUT_PREFIX"
else
    # Explicit --out: no auto-suffix. Refuse-unless-force.
    if [ "$FORCE" != "true" ]; then
        # shellcheck disable=SC2086
        EXISTING=$(any_exist $(target_files_for "$OUT_PREFIX") || true)
        if [ -n "$EXISTING" ]; then
            echo "Refusing to overwrite existing: $EXISTING (use --force)" >&2
            exit 1
        fi
    fi
fi

AUDIO_OUT="${OUT_PREFIX}.mp3"
JSON_OUT="${OUT_PREFIX}.json"
WORDS_JSON="${OUT_PREFIX}.words.json"
SENTS_JSON="${OUT_PREFIX}.sentences.json"
WORDS_SRT="${OUT_PREFIX}.words.srt"
SENTS_SRT="${OUT_PREFIX}.sentences.srt"

# ── Temp files for request/response ───────────────────────────────────────────
HDR_FILE=$(mktemp /tmp/eltts_hdr_XXXXXX)
BODY_TMP=$(mktemp /tmp/eltts_body_XXXXXX)
HDR_DUMP=$(mktemp /tmp/eltts_resp_hdr_XXXXXX)
trap 'rm -f "$HDR_FILE" "$BODY_TMP" "$HDR_DUMP"' EXIT INT TERM

# Header file with mode 600 — keeps API key out of argv / set -x traces
chmod 600 "$HDR_FILE"
printf 'xi-api-key: %s\nContent-Type: application/json\n' "$ELEVENLABS_API_KEY" > "$HDR_FILE"

# ── Build request body (JSON-safe via python sys.argv) ────────────────────────
REQ_JSON=$(python3 - "$TEXT" "$MODEL" "$STABILITY" "$SIMILARITY" "$STYLE" "$SPEED" "$SPEAKER_BOOST" <<'PYEOF'
import sys, json
text, model, stab, sim, style, speed, boost = sys.argv[1:]
body = {
    "text": text,
    "model_id": model,
    "voice_settings": {
        "stability": float(stab),
        "similarity_boost": float(sim),
        "style": float(style),
        "speed": float(speed),
        "use_speaker_boost": boost == "true",
    }
}
print(json.dumps(body))
PYEOF
)

# ── Call ElevenLabs ───────────────────────────────────────────────────────────
ENDPOINT="https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}/with-timestamps?output_format=${FORMAT}"

echo "Synthesizing (voice=${VOICE}, model=${MODEL})..."

HTTP_CODE=$(curl -sS -w '%{http_code}' -o "$BODY_TMP" -D "$HDR_DUMP" \
    -X POST "$ENDPOINT" \
    -H "@$HDR_FILE" \
    -d "$REQ_JSON")

if [ "$HTTP_CODE" != "200" ]; then
    BODY=$(grep -v -i '^xi-api-key' "$BODY_TMP" 2>/dev/null || cat "$BODY_TMP")
    echo "Error: ElevenLabs API returned HTTP $HTTP_CODE" >&2
    case "$HTTP_CODE" in
        401)
            if echo "$BODY" | grep -qi 'quota_exceeded'; then
                echo "Free tier quota exhausted." >&2
            fi
            ;;
        404|422)
            echo "" >&2
            echo "If the voice_id '$VOICE_ID' is no longer valid, look up the current Chris ID with:" >&2
            echo "  curl -H \"xi-api-key: \$ELEVENLABS_API_KEY\" https://api.elevenlabs.io/v1/voices \\" >&2
            echo "    | jq '.voices[] | select(.name==\"Chris\") | .voice_id'" >&2
            echo "Then re-run with --voice <id>." >&2
            ;;
    esac
    echo "" >&2
    echo "Response body:" >&2
    echo "$BODY" >&2
    exit 1
fi

# ── Optionally fetch subscription totals (requires user_read permission) ──────
# TTS-only keys lack this permission; that's expected on the free tier. Fail silently.
SUB_TMP=$(mktemp /tmp/eltts_sub_XXXXXX)
trap 'rm -f "$HDR_FILE" "$BODY_TMP" "$HDR_DUMP" "$SUB_TMP"' EXIT INT TERM
SUB_CODE=$(curl -sS -w '%{http_code}' -o "$SUB_TMP" \
    "https://api.elevenlabs.io/v1/user/subscription" \
    -H "@$HDR_FILE" 2>/dev/null || echo "000")
if [ "$SUB_CODE" != "200" ]; then
    : > "$SUB_TMP"   # blank file signals "no subscription data"
fi

# ── Parse response, decode audio, build timing artifacts ──────────────────────
python3 - "$BODY_TMP" "$HDR_DUMP" "$SUB_TMP" "$AUDIO_OUT" "$JSON_OUT" \
           "$WORDS_JSON" "$SENTS_JSON" "$WORDS_SRT" "$SENTS_SRT" \
           "$TEXT" "$VOICE" "$VOICE_ID" "$MODEL" "$AUDIO_ONLY" <<'PYEOF'
import sys, json, base64, re, datetime

(body_path, hdr_path, sub_path, audio_out, json_out,
 words_json, sents_json, words_srt, sents_srt,
 text, voice, voice_id, model, audio_only_flag) = sys.argv[1:]

audio_only = audio_only_flag == "true"

with open(body_path) as f:
    resp = json.load(f)

# ── Decode audio (field-name fallback chain) ──────────────────────────────────
payload = resp.get("audio_base64") or resp.get("audio_base_64") or resp.get("audio")
if not payload:
    sys.stderr.write(
        "Error: response contained no audio field. Top-level keys: "
        + ", ".join(sorted(resp.keys())) + "\n"
    )
    sys.exit(1)

with open(audio_out, "wb") as f:
    f.write(base64.b64decode(payload))

# ── Per-call cost from response headers ───────────────────────────────────────
def parse_headers(path):
    hdrs = {}
    with open(path, errors="replace") as f:
        for line in f:
            if ":" not in line:
                continue
            k, _, v = line.partition(":")
            hdrs[k.strip().lower()] = v.strip()
    return hdrs

hdrs = parse_headers(hdr_path)
cost_s = hdrs.get("character-cost", "")
call_cost = int(cost_s) if cost_s.lstrip("-").isdigit() else None

# ── Subscription totals (optional; 401 on TTS-only keys) ──────────────────────
used = limit = resets_at = None
try:
    with open(sub_path) as f:
        raw = f.read().strip()
    if raw:
        sub = json.loads(raw)
        used  = sub.get("character_count")
        limit = sub.get("character_limit")
        reset_unix = sub.get("next_character_count_reset_unix")
        if isinstance(reset_unix, (int, float)) and reset_unix > 0:
            try:
                resets_at = datetime.datetime.utcfromtimestamp(int(reset_unix)).strftime("%Y-%m-%d")
            except (ValueError, OSError):
                resets_at = None
except (OSError, json.JSONDecodeError):
    pass

quota = {
    "call_cost": call_cost,   # chars charged for this synthesis (always available)
    "used": used,             # account-level total; null if key lacks user_read
    "limit": limit,
    "resets_at": resets_at,
}

def quota_summary():
    parts = []
    if call_cost is not None:
        parts.append(f"This call: {call_cost:,} chars")
    if used is not None and limit is not None:
        totals = f"total: {used:,} / {limit:,}"
        if resets_at:
            totals += f", resets {resets_at}"
        parts.append(totals)
    return " | ".join(parts)

# ── Audio-only shortcut ───────────────────────────────────────────────────────
if audio_only:
    print(f"Audio:     {audio_out}")
    s = quota_summary()
    if s:
        print(s)
    sys.exit(0)

# ── Pick alignment source (prefer original; fall back to normalized) ──────────
align = resp.get("alignment") or resp.get("normalized_alignment") or {}
chars  = align.get("characters", [])
starts = align.get("character_start_times_seconds", [])
ends   = align.get("character_end_times_seconds", [])

if not chars or len(chars) != len(starts) or len(chars) != len(ends):
    sys.stderr.write("Warning: alignment arrays missing or mismatched; timing outputs will be empty.\n")
    out = {
        "text": text, "voice": voice, "voice_id": voice_id, "model": model,
        "audio_file": audio_out,
        "characters": [], "words": [], "sentences": [],
        "quota": quota,
    }
    with open(json_out, "w") as f:
        json.dump(out, f, indent=2)
    # Empty split JSONs + SRTs still emitted so downstream tooling doesn't fault on missing files
    for p, payload in ((words_json, []), (sents_json, [])):
        with open(p, "w") as f:
            json.dump(payload, f, indent=2)
    for p in (words_srt, sents_srt):
        open(p, "w").close()
    print(f"Audio:     {audio_out}")
    print(f"Timings:   {json_out} (alignment unavailable)")
    sys.exit(0)

# ── Character entries (iterate by index; entry may be multi-codepoint) ────────
def is_ws(entry):
    return entry.strip() == ""

char_entries = []
for i, c in enumerate(chars):
    char_entries.append({"char": c, "start": starts[i], "end": ends[i]})

# ── Word grouping: maximal runs of non-whitespace entries ─────────────────────
words = []
n = len(chars)
i = 0
while i < n:
    if is_ws(chars[i]):
        i += 1
        continue
    j = i
    while j < n and not is_ws(chars[j]):
        j += 1
    words.append({
        "word": "".join(chars[i:j]),
        "start": starts[i],
        "end": ends[j - 1],
        "char_start": i,
        "char_end": j - 1,
    })
    i = j

# ── Sentence grouping ─────────────────────────────────────────────────────────
# A word ends a sentence iff ALL of:
#   - stripped tail (trailing "'*)}]>”’’” etc. removed) ends in .!?
#   - word body (terminator stripped) is NOT in abbreviation stop-list
#   - next word's first letter is uppercase/digit/opening-quote-then-upper, OR this is the last word
STOP_LIST = {
    "Dr", "Mr", "Mrs", "Ms", "Prof", "Jr", "Sr", "St", "Ave", "Rd", "Blvd",
    "Inc", "Ltd", "Co", "Corp", "vs", "etc", "eg", "ie", "cf", "approx",
}
CLOSING_PUNCT = '"\'*)}]>”’'  # strip trailing closing-punctuation before testing for terminator

def is_terminator_tail(word_text):
    stripped = word_text.rstrip(CLOSING_PUNCT)
    return bool(stripped) and stripped[-1] in ".!?…"

def body_no_terminator(word_text):
    stripped = word_text.rstrip(CLOSING_PUNCT)
    # Remove run of trailing terminators (handles ..., ?!, …)
    return stripped.rstrip(".!?…")

def next_word_starts_sentence(next_word):
    # Skip opening punctuation, then check first alpha/digit
    w = next_word.lstrip('"\'([{‘“')
    if not w:
        return False
    return w[0].isupper() or w[0].isdigit()

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
    if is_last or (term and next_word_starts_sentence(words[wi + 1]["word"])):
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

# ── Write JSON ────────────────────────────────────────────────────────────────
out = {
    "text": text, "voice": voice, "voice_id": voice_id, "model": model,
    "audio_file": audio_out,
    "characters": char_entries,
    "words": words,
    "sentences": sentences,
    "quota": quota,
}
with open(json_out, "w") as f:
    json.dump(out, f, indent=2)

# ── Split JSONs for context-selective loading downstream ──────────────────────
with open(words_json, "w") as f:
    json.dump(words, f, indent=2)
with open(sents_json, "w") as f:
    json.dump(sentences, f, indent=2)

# ── SRT writers ───────────────────────────────────────────────────────────────
def fmt_srt_time(t):
    if t < 0:
        t = 0
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
            end = max(e["end"], start + 0.001)  # clamp so zero-duration cues aren't dropped
            f.write(f"{i}\n{fmt_srt_time(start)} --> {fmt_srt_time(end)}\n{e[text_key]}\n\n")

write_srt(words_srt, words, "word")
write_srt(sents_srt, sentences, "sentence")

# ── Report ────────────────────────────────────────────────────────────────────
print(f"Audio:      {audio_out}")
print(f"Full JSON:  {json_out}")
print(f"Words JSON: {words_json}  ({len(words)} items)")
print(f"Sents JSON: {sents_json}  ({len(sentences)} items)")
print(f"Words SRT:  {words_srt}  ({len(words)} cues)")
print(f"Sents SRT:  {sents_srt}  ({len(sentences)} cues)")
s = quota_summary()
if s:
    print(s)
PYEOF
