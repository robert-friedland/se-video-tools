Local whisper.cpp transcription for any video or audio file. Produces word-level and sentence-level timings (JSON + SRT), plain text, and a `likely_interview` classifier that separates speech-heavy clips from b-roll. **Use this instead of raw `whisper-cli` or ad-hoc `ffmpeg + whisper-cli` pipelines.** Free (no API credits), ~5–10× realtime on Apple Silicon.

**TRIGGER** on any of these — keyword match is enough, don't wait for full context:
- The words **"transcribe"**, **"transcription"**, or **"transcript"** (verb or noun) pointed at a video, audio, clip, recording, interview, call, or meeting
- **"STT"**, **"speech to text"**, **"speech-to-text"**, **"voice to text"**, **"audio to text"**
- **"captions"**, **"subtitles"**, **"SRT"**, **"VTT"**, **"WebVTT"** for a video or audio file
- **"what did X say"**, **"what's being said"**, **"dialogue from"**, **"quotes from"** a clip
- Get timestamps, word-level timings, or sentence boundaries from a recording
- Classify, catalog, or organize a folder of video footage where interview-vs-b-roll matters
- Pair a video with its transcript
- **Any plan that invokes `whisper-cli` directly** — reroute through this skill. It wraps the same binary but also emits sentence timings, a classifier, and Resolve-compatible SRTs that downstream `se-video-tools` commands depend on.

**SKIP** (different tools handle these):
- TTS / text-to-speech / narration / voice-over generation → `/elevenlabs-tts`
- "What's visually shown in this video" with no speech component → `/analyze-video`
- Clap-based audio sync between two clips → `/sync-clap`

## When NOT to transcribe

Skip only if the user explicitly says "don't transcribe" or already has transcripts. Being asked to *organize*, *catalog*, or *classify* videos is an implicit transcribe trigger for any clip that might contain speech — the `likely_interview` flag is the classifier.

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
- `--prompt TEXT` — initial-prompt context passed to Whisper. Biases the model toward punctuated, capitalized output so the sentence splitter has something to work with. Default is a neutral interview-style hint. The prompt itself never appears in the transcript. Override for domain-specific vocabulary (e.g. `--prompt "Hello. Welcome to this Squint customer call. Punctuate properly."`).
- `--no-prompt` — disable the default initial prompt entirely. Only useful if you're seeing prompt bleedthrough or want to reproduce pre-fix behavior.
- `--force` — overwrite existing outputs (otherwise clips with a complete output set are skipped).
- `--keep-wav` — keep the extracted 16 kHz WAV next to the video (otherwise deleted after transcription). Note: deliberately NOT named `--audio-only` to avoid colliding with `elevenlabs_tts --audio-only`, which means "skip timing outputs" — opposite intent.

**Why the default prompt matters:** Without an initial prompt, Whisper sometimes emits completely unpunctuated, uncapitalized output on certain audio (British accents + noisy industrial environments were the repro in our test set). When that happens, the sentence splitter can't find `.!?` terminators and collapses to one 6000+ char "sentence." Passing even a short punctuated prompt reliably forces the model into its formatted-output mode. If you still see a `WARNING: no punctuation found` line in stdout, re-run with a custom `--prompt` tuned to the domain.

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

## Typical workflow for cataloging a folder of mixed footage

Use this when the task is "classify / organize / catalog these videos" and the pile includes some mix of interviews, b-roll, and app-usage or screen-recording clips.

```bash
# 1. Transcribe the whole folder — this IS the first-pass classifier.
transcribe ~/Downloads/Onsite-XYZ
# Clips with likely_interview=true are your interview candidates.
# Clips with likely_interview=false are either b-roll or Squint-usage/screen
# recordings. Disambiguate those visually (see step 2).
```

`transcribe` handles the interview-vs-everything-else split. To split b-roll from on-screen/app-usage clips among the non-interview set, fall back to `analyze-video` (frame sampling). Do this second, not first — transcripts are cheaper to scan than frames, and the speech ratio alone eliminates ~80% of clips from visual inspection.

Do NOT:
- Run `whisper-cli` directly and regenerate this skill's outputs by hand. The `.sentences.json`, `.words.srt`, and `.summary` block are what downstream tools (`elevenlabs-tts`, `organize-onsite`, clip-selection workflows) expect to see sitting next to the video.
- Extract audio with `ffmpeg -ac 1 -ar 16000` yourself before running whisper. `transcribe` already does this, then cleans up the WAV afterward.
- Skip transcription on long clips because "they're probably b-roll." The classifier is the point — run it, then read the flag.
