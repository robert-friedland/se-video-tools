Transcribe interview footage (or any video) locally with whisper.cpp. Produces word-level and sentence-level timings alongside each video, plus a `likely_interview` flag that distinguishes clips with sustained speech from b-roll. Free (no API credits) and runs at ~5–10× realtime on Apple Silicon.

## Your job when this skill is invoked

1. **Pre-flight:** confirm `whisper-cli` and `ffmpeg` are on PATH. If `whisper-cli` is missing, tell the user to `brew install whisper-cpp`. If the default model (`ggml-large-v3-turbo.bin`) isn't cached, the tool will auto-download it (~1.5 GB) on first run — warn the user so they don't think it hung.
2. **Resolve the target:**
   - Single file (`transcribe foo.mp4`) — one pass, one output set.
   - Folder (`transcribe ~/Onsites/2026-04-idexx`) — non-recursive, processes every video with a matching extension.
3. **Run `transcribe`** and capture stdout. The per-file line reports word count, speech duration, and the `interview` / `not-interview` classification. The end-of-run summary table is the primary deliverable for folder runs.
4. **Report outputs.** Each video `<name>.mp4` gets six sidecar files; lead with `.sentences.json`.
5. **Downstream use for "find quotes in interviews"**:
   - Load `<name>.transcript.sentences.json` (top-level array of `{sentence, start, end, word_start, word_end}`) — smallest context footprint, enough for picking quotable lines.
   - Load `<name>.transcript.words.json` only when the user wants to trim a quote mid-sentence (precise in/out cut points).
   - The combined `<name>.transcript.json` has the `.summary` block — `likely_interview`, `word_count`, `speech_ratio`. Use this to filter a folder to just the interview clips before scanning sentences.

## Command

```bash
transcribe <video-or-folder> [OPTIONS]
transcribe update
```

Options:
- `--model NAME_OR_PATH` — model short name (`tiny.en`, `base.en`, `small.en`, `medium.en`, `large-v3`, `large-v3-turbo`) or explicit `.bin` path. Default: `large-v3-turbo` (best accuracy/speed tradeoff on Apple Silicon).
- `--language CODE` — language hint; default `en`. Use `auto` for detection (slower; only matters on non-English).
- `--ext LIST` — comma-separated extensions to process in folder mode. Default: `mp4,mov,m4v,mkv,MP4,MOV,M4V,MKV,wav,mp3`.
- `--min-words N` — minimum real (non-bracketed) word count to flag as `likely_interview`. Default: 30.
- `--threads N` — pass-through to `whisper-cli`.
- `--force` — overwrite existing outputs (otherwise clips with a complete output set are skipped).
- `--keep-wav` — keep the extracted 16 kHz WAV next to the video (otherwise deleted after transcription). Note: deliberately NOT named `--audio-only` to avoid colliding with `elevenlabs_tts --audio-only`, which means "skip timing outputs" — opposite intent.

## Output files

For each input `<name>.mp4`:

```
<name>.transcript.sentences.json      [{sentence, start, end, word_start, word_end}, ...]   ← load this first
<name>.transcript.words.json          [{word, start, end}, ...]
<name>.transcript.json                combined: {source, model, language, duration,
                                                text, words[], sentences[], summary}
<name>.transcript.words.srt           Resolve-compatible (one cue per word)
<name>.transcript.sentences.srt       Resolve-compatible (one cue per sentence)
<name>.transcript.txt                 plain text, sentence-per-line
```

The `.summary` block inside `<name>.transcript.json`:

```
.summary.word_count         real words (bracketed non-speech markers like [BLANK_AUDIO] excluded)
.summary.speech_seconds     sum of word durations
.summary.duration_seconds   video duration (from ffprobe)
.summary.speech_ratio       speech_seconds / duration_seconds (capped implicitly by Whisper)
.summary.likely_interview   bool: word_count >= min_words AND (ratio >= 0.15 OR duration unknown)
```

## Key facts

- **No API costs.** Runs entirely locally via whisper.cpp. First run downloads the model to `~/.whisper-models/` (~1.5 GB for `large-v3-turbo`).
- **Classifier is heuristic, not gate.** Every clip gets transcribed — the flag is metadata. This is intentional: Whisper hallucinates "Thank you." on silent b-roll, so the word-count threshold is the discriminator. If you want to filter a folder to interviews, read each `.summary.likely_interview` and act on it.
- **Sentence grouping uses the same heuristic as `elevenlabs_tts`** — abbreviation stop-list (`Dr`, `Mr`, `etc`, …) + capital-next-word lookahead. Spot-check boundaries if the interview has unusual punctuation.
- **Bracketed markers** (`[BLANK_AUDIO]`, `[Music]`, etc.) are stripped from the word list but preserved in the raw text if that's all there is. They never count toward `word_count`.
- **Skips already-processed files** by default. Pass `--force` to regenerate.
- **`transcribe update`** refreshes the tool and this skill file.

## Typical workflow for interview-quote selection

```
# 1. Transcribe a folder of onsite footage
transcribe ~/Onsites/2026-04-idexx

# Summary:
# file                    words  speech(s)  dur(s)  ratio  interview?
# Brian Interview.MP4     812    428.3      445.1   0.96   yes
# Dustin Interview.MP4    691    385.2      402.4   0.96   yes
# Filler B Roll 1.MP4     2      30.0       8.4     3.57   no
# ...

# 2. For each interview clip, scan sentences for a theme
jq -r '.[] | "\(.start)\t\(.end)\t\(.sentence)"' "Brian Interview.transcript.sentences.json"

# 3. Once you pick a quote, its (start, end) become the cut points for that clip.
```

To filter a folder to only the likely-interview clips:

```bash
for f in *.transcript.json; do
  jq -e '.summary.likely_interview' "$f" >/dev/null && echo "$f"
done
```
