End-to-end playbook for cutting a multi-interview rough cut: pick quotes, time them precisely, layer b-roll that bridges every gap, and emit a Resolve-ready xmeml. Use this when the user wants a finished rough cut from a folder of interview clips, not just a single trim.

**TRIGGER** when the user says any of:
- **"rough cut"**, **"rough cut from these interviews"**, **"build a rough cut"**, **"interview cut"**, **"talking-head video"**, **"customer interview video"**, **"hero customer video"**
- The user points at a folder of interview footage and wants a single edited sequence with quotes spliced together
- Any combination of "transcribe these and pick the good quotes" + "build a timeline" — that's two skills run in sequence; this is the one that orchestrates them
- The user complains about word-clipping, black flashes between cuts, or repetitive b-roll in a previous rough cut — those are the three problems this playbook is designed to avoid

**SKIP** when:
- The user just wants a transcript (`/transcribe`)
- The user already has a finalized JSON cut list and just wants xmeml (`/build-timeline` directly)
- A single-clip trim or a screen-recording composite (`ipad_bezel`, `composite_bezel`)
- The work is purely b-roll with no interview/dialog spine

## The pipeline

```bash
resolve_phrases cuts.json - | bridge_broll - | build_timeline - rough.xml
```

Three tools, each does one thing. Together they take a phrase-based JSON cut list with a per-beat b-roll plan, and produce a Resolve-importable xmeml with V1 (talking heads, padded), V2 (b-roll, contiguous, no black flashes), and A1 (linked dialog audio).

## Workflow

### 1. Transcribe everything

```bash
transcribe /path/to/footage-folder
```

The classifier splits interviews from b-roll automatically (look at `.summary.likely_interview` in each `.transcript.json`). Each interview now has a `.transcript.sentences.json` next to it — that's where you pick quotes from.

### 2. Pick quotes from sentences.json

For each beat (idea you want in the video), find a sentence (or contiguous sub-phrase) that says it well. Capture:
- `source`: absolute path to the interview MP4
- `phrase`: **byte-identical** text from `.transcript.sentences.json` (single-spaced, punctuation included)
- `near`: the `start` of the first sentence the phrase touches
- `label`: optional, for your own notes

### 3. Plan b-roll per beat

For every V1 beat, list 1–N b-roll shots that should overlay it. Each shot needs `source` and (optionally) `source_in` and `label`. The total `source_dur − source_in − clearance` across the beat's shots must cover the V2 span (`bridge_broll` errors out clearly if it doesn't).

**Rules of thumb:**
- **Never reuse the same `(source, source_in)` segment** — viewers notice. If you need more time on a long source, use the same source with a different `source_in` so the visible content differs.
- **"Branded apparel ≠ product in action."** A clip of a person wearing the company's branded shirt does *not* count as showing the product. The product is the screen / UI / artifact. Score b-roll on what's actually visible, not what's on someone's vest.
- **Frame-rate normalize external footage before adding it.** If you're harvesting clips from a different source (e.g. a marketing recap reel), check `ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate` and re-encode with `-r 30000/1001` (or whatever the timeline rate is) before referencing the clip. `build_timeline` rejects mismatched-rate sources.
- **Aim for ≥50% "product on screen" coverage** in a customer-facing product video. The remainder can be environment/factory/context. Track this — it's the metric that separates a video that *shows* the product from one that *talks about* it.

For mining b-roll candidates from a long supplementary clip (e.g. a marketing recap), use `/analyze-video` to scan frames at fixed intervals and report which time ranges contain product UI; then `ffmpeg -ss S -t D -r <timeline_rate> -c:v libx264 -crf 18 input.mov candidate_NN.mp4` for each candidate range.

### 4. Author the JSON cut list

Single file, in the multi-track shape with a top-level `v2_plan`:

```json
{
  "name": "Customer Rough Cut",
  "tracks": {
    "V1": [
      {"source": "/abs/iv1.mp4", "phrase": "...", "near": 88.83, "label": "Beat 1"},
      {"gap": 0.4},
      {"source": "/abs/iv2.mp4", "phrase": "...", "near": 128.9, "label": "Beat 2"}
    ]
  },
  "v2_plan": [
    [
      {"source": "/abs/broll1.mp4", "source_in": 0.0, "label": "ui shot"},
      {"source": "/abs/broll2.mp4", "source_in": 0.0, "label": "context"}
    ],
    [
      {"source": "/abs/broll3.mp4", "source_in": 0.0, "label": "feature in use"}
    ]
  ]
}
```

`v2_plan` length must match V1 non-gap count exactly. Use `[]` for a beat you intentionally want to leave on the talking head.

### 5. Run the pipeline

```bash
resolve_phrases cuts.json - | bridge_broll - | build_timeline - rough.xml
```

Then tell the user: `File → Import → Timeline…` in Resolve, point at `rough.xml`. Resolve auto-links sources.

### 6. Verify (optional but recommended on first build)

If the user reports word-clipping, **don't immediately add more lead/trail.** Verify first:

```bash
ffmpeg -ss <start> -t <duration> -i <source> /tmp/check.wav
transcribe /tmp/check.wav --force
cat /tmp/check.transcript.txt
```

Whisper sometimes truncates "incomplete-sounding" sentence endings as a display artifact even when the audio is fully present (e.g. transcribes `"...not just my..."` for a clip that actually contains `"...not just my department, it would help with quality."`). The way to confirm is to widen the window and re-transcribe — if the wider window shows the words, the audio is correct and no more padding is needed.

## What each tool actually does

| Tool | Input | Output | What it does |
|---|---|---|---|
| `transcribe` | interview folder | `*.transcript.{json,sentences.json,words.json,txt,srt}` | Whisper STT + interview classifier |
| `resolve_phrases` | phrase-based JSON | time-based JSON (`start`/`duration` per V1 cut) | Snaps phrase to exact word boundaries |
| `bridge_broll` | resolved JSON + `v2_plan` | resolved JSON with padded V1 + contiguous V2 | Pads V1 cuts; distributes b-roll to bridge V1 gaps |
| `build_timeline` | resolved JSON | xmeml v5 | ffprobes sources; emits Resolve-importable timeline |

`bridge_broll` is the new one — it replaces the manual "compute v2 segments by hand" step. Defaults: `--v1-lead 0.10 --v1-trail 0.20 --v2-head-show 1.0 --v2-tail-show 0.5 --v2-clearance 0.34`. Override per-input with a top-level `bridge_broll_options` object, or via CLI flags.

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `phrase not found in <file>` | Quote was paraphrased, not byte-identical to sentences.json | Re-copy from `.transcript.sentences.json` |
| `ambiguous phrase ... multiple matches near=N` | Same phrase recurs and `near` doesn't disambiguate | Narrow the phrase, or set per-segment `window` |
| `v2_plan has N beats but V1 has M non-gap cuts` | Plan and V1 out of sync | Add/remove plan entries; use `[]` for empty beats |
| `source budget X < beat span Y` | Beat's b-roll plan can't cover its V1 span | Add another shot to that beat's plan, or pick a longer source segment / lower `source_in` |
| `frame rate mismatch` from `build_timeline` | Externally-harvested b-roll at different fps | Re-encode at timeline rate: `ffmpeg -r 30000/1001 -i in.mp4 ...` |
| Black flashes between V1 cuts in Resolve | Empty beat plan, or V2 didn't fill the gap | Check `bridge_broll` stderr for "non-contiguous V2 transitions" warnings; fill empty plans |
| Clip goes "offline" (red placeholder) in Resolve | xmeml source out exceeds source frame count | Ensure `--v2-clearance` (default 0.34s ≈ 10 frames) is respected — never set `source_in` past `source_dur − clearance` |
| Every clip plays from wrong source position by ~30s | DF/NDF tagging mismatch | `build_timeline` ffprobes embedded TC — if it's wrong, regenerate; don't hand-edit xmeml |

## Optional review loop (Notion)

If the user has `notion-cli` set up and asks for stakeholder review of the script *before* you build the timeline, post the V1 quote selection as a Notion plan page (see global CLAUDE.md). Otherwise skip — review can happen by sharing the rough.xml output directly.

## Do NOT

- **Don't reuse a `(source, source_in)` segment** across beats. Even at different `source_in` offsets, treat the same source as having a finite usable budget across the whole timeline.
- **Don't hand-author V2 entries** when you have a per-beat plan. `bridge_broll` is the right tool — it does the proportional fill, clearance bookkeeping, and contiguity checks for you.
- **Don't add lead/trail past 0.20s** as a reflex when whisper transcripts look truncated. Verify the audio first by re-transcribing a wider window.
- **Don't include a music track** unless the user asks. If they do, generate it independently (out of scope for this playbook).
- **Don't pass `2>&1` in the middle of the pipe** — `bridge_broll` writes a one-line summary to stderr; merging it into stdout corrupts the JSON stream feeding `build_timeline`. Use `2>/dev/null` or let stderr render naturally.
