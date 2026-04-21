Generate ElevenLabs narration with per-character, per-word, and per-sentence timings. Outputs are split across multiple JSON files so downstream workflows can load only the granularity they need (e.g. `.sentences.json` for clip-selection, `.words.json` for precise cut points) without pulling the full character-level data into context.

## Your job when this skill is invoked

1. **Pre-flight:** confirm `ELEVENLABS_API_KEY` is set. If `[ -z "$ELEVENLABS_API_KEY" ]`, tell the user to `export ELEVENLABS_API_KEY=sk_...` and stop.
2. **Resolve the narration text:**
   - If the user provided inline text or a `--text-file` path, use it.
   - If they did not, ask exactly once: "Paste the narration, or give me a path to a text file?"
   - If the user responds with "just make one up", "you write it", or similar, draft the narration text, show it in the chat, and get explicit confirmation before calling the tool. Never silently generate narration and send it to the API.
3. **Pick `--out`** based on context (filename of the related video if any; otherwise rely on the tool's derived prefix). The tool auto-suffixes collisions (`_1`, `_2`, …) when `--out` is not set, so iterating on takes of the same narration is painless.
4. **Run `elevenlabs_tts`** and capture stdout. Note the `Using prefix: …` line — that's the chosen basename for all six outputs.
5. **Report the output paths**, leading with `.sentences.json`.
6. **Primary downstream use** — the split JSONs are the handoff artifacts for narration-driven clip selection. **Load `.sentences.json` first** — it's the smallest and enough for scene-level clip matching. Only load `.words.json` if you need precise in/out cut points inside a sentence. Only load the combined `.json` if you specifically need `.characters[]` or the metadata header. `/analyze-video` does NOT accept a narration JSON natively; the bridge is manual. The pattern:
   - Read `.sentences.json` as a top-level array of `{sentence, start, end, word_start, word_end}`.
   - For each sentence, invoke `/analyze-video` against the candidate background footage with the sentence text as the subject you're looking for, OR call `extract_frames <footage> <N> <dir> --start $start --stop $end` against a known candidate range to visually verify a match.
   - Once a matching footage segment is found, the sentence's `(start, end)` become the cut-in/cut-out points for that clip on the narration timeline.
   The `.srt` files are only relevant when the user explicitly asks for Resolve captions.

## Command

```bash
elevenlabs_tts [OPTIONS] "text to speak"
elevenlabs_tts [OPTIONS] --text-file path.txt
elevenlabs_tts --list-voices
```

Options:
- `--voice NAME_OR_ID` — built-in name (`Chris`, `Rachel`, `Adam`, `Antoni`, `Bella`, `Elli`, `Josh`, `Sam`, `Domi`) or a 20-char raw voice_id (default: `Chris`).
- `--model ID` — `eleven_multilingual_v2` (default), `eleven_turbo_v2_5`, or `eleven_flash_v2_5`. `eleven_v3` is NOT supported on `/with-timestamps`.
- `--stability 0..1` (default: 0.5), `--similarity 0..1` (0.75), `--style 0..1` (0.0), `--speed 0.7..1.2` (1.0), `--no-speaker-boost`.
- `--format FMT` — e.g. `mp3_44100_128` (default; free-tier max).
- `--text-file PATH` — read narration from file (mutually exclusive with positional).
- `--out PREFIX` — explicit output basename (disables auto-suffix).
- `--audio-only` — skip JSON + SRT; write only the `.mp3`.
- `--force` — overwrite existing files.

To use a different API key for one run, prefix the call: `ELEVENLABS_API_KEY=sk_xxx elevenlabs_tts ...`.

## Output files

```
$PREFIX.mp3                 audio
$PREFIX.sentences.json      [{sentence, start, end, word_start, word_end}, ...]   ← load this first
$PREFIX.words.json          [{word, start, end, char_start, char_end}, ...]
$PREFIX.json                combined: {text, voice, voice_id, model, audio_file,
                                      characters[], words[], sentences[], quota}
$PREFIX.words.srt           Resolve-compatible subtitle file (word granularity)
$PREFIX.sentences.srt       Resolve-compatible subtitle file (sentence granularity)
```

The split `.words.json` and `.sentences.json` are top-level arrays — no wrapping object — so downstream consumers can `jq '.[] | ...'` or pass them straight to a loader.

The combined `$PREFIX.json` contains everything plus metadata:
```
.text                    original narration text
.voice / .voice_id       voice identifier
.model                   model used
.audio_file              path to the .mp3

.characters[] = {char, start, end}
.words[]      = {word, start, end, char_start, char_end}
.sentences[]  = {sentence, start, end, word_start, word_end}

.quota = {
  call_cost,              // chars charged for this synthesis (always populated)
  used, limit, resets_at  // account-level totals; null on TTS-only keys
                          // (totals require user_read permission on the API key)
}
```

All `start` / `end` values are seconds (float), aligned to the rendered audio.

Typical extraction pattern for scripted use:

```bash
jq -r '.[] | "\(.start)\t\(.end)\t\(.sentence)"' out.sentences.json
```

## Key facts

- Default voice is **Chris**. Any ElevenLabs premade voice works via `--voice`; any other voice can be passed as a raw 20-char ID.
- **Free tier:** ~10k chars/month. The tool prints this call's character cost after each run. Account-level running totals are only available when the API key has the `user_read` permission; TTS-only keys (common for narrow-scope deployments) show `null` for `used`/`limit`/`resets_at`. A 401 with `quota_exceeded` is surfaced as a dedicated error.
- **Sentence splitter is heuristic.** It uses an abbreviation stop-list (`Dr`, `Mr`, `Mrs`, `Ms`, `Prof`, `Jr`, `Sr`, `St`, `Ave`, `Rd`, `Blvd`, `Inc`, `Ltd`, `Co`, `Corp`, `vs`, `etc`, `eg`, `ie`, `cf`, `approx`) plus a capital-next-word lookahead rule. Spot-check sentence boundaries if the narration has unusual punctuation (nested quotes, foreign abbreviations, URLs with dots).
- **Derived prefix** (when `--out` not given) is the first 40 chars of the text, lowercased and slug-ified. Collisions auto-suffix `_1`, `_2`, … up to `_999`; the chosen prefix is printed on stdout as `Using prefix: <name>`.
- **Overwrite protection:** with `--out PREFIX`, the tool refuses to overwrite existing artifacts unless `--force` is passed. The "existing" set is scoped to just the files this invocation will write (so a prior `.json` does not block an `--audio-only` re-run).
- **Voice_id recovery:** if the default Chris ID ever drifts, a 404/422 response prints a one-liner showing how to fetch the current ID from `/v1/voices`.
- `elevenlabs_tts update` refreshes the tool and this skill file.

## Typical workflow

```
elevenlabs_tts "Welcome to the demo. Today we'll see the new interface."
→ Using prefix: welcome_to_the_demo_today
  Audio:      welcome_to_the_demo_today.mp3
  Full JSON:  welcome_to_the_demo_today.json
  Words JSON: welcome_to_the_demo_today.words.json  (9 items)
  Sents JSON: welcome_to_the_demo_today.sentences.json  (2 items)
  Words SRT:  welcome_to_the_demo_today.words.srt  (9 cues)
  Sents SRT:  welcome_to_the_demo_today.sentences.srt  (2 cues)
  This call: 51 chars
```

Then, to match sentences to background footage:
```
jq -r '.[] | "\(.start)\t\(.end)\t\(.sentence)"' welcome_to_the_demo_today.sentences.json
# For each sentence, run /analyze-video or extract_frames against candidate footage
# and use the (start, end) as cut points.
```
