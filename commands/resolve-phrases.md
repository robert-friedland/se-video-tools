Resolve a phrase-based JSON cut list into a time-based JSON cut list with exact word-level start/end timings, ready for `build_timeline`. Use this **between** picking quotes from `.transcript.sentences.json` and emitting the xmeml — it's the step that turns "the words I want" into "the precise timestamps where those words start and stop."

**TRIGGER** when:
- The user complains about clip timings cutting off words
- You're building a cut list from interview transcripts and want word-precise edges, not sentence-rounded ones
- The user mentions "dial in", "phrase-based", "word-level timing", "exact cut", or anything pointing at boundary precision
- Anywhere you'd otherwise hand `build_timeline` a cut list with sentence-level start/duration

**SKIP** when:
- The cut list is for B-roll, screen recordings, or anything without a `.transcript.words.json` next to it (those segments stay time-based)
- The user has already authored exact start/duration values they want preserved

## Workflow (the whole point)

1. **Pick quotes from `.transcript.sentences.json`.** Read the file, find sentences with the ideas you want, identify the **exact text** you want in the video (which may be a sub-phrase of a sentence or a span across sentence boundaries — anything contiguous).
2. **Author phrase-based JSON.** For each quote, capture:
   - `source`: absolute path to the source MP4
   - `phrase`: **verbatim** text from sentences.json, including attached punctuation (e.g. `"the new system,"` not `"the new system"` if the comma is in the transcript)
   - `near`: the start time of the **first sentence** the phrase touches (copy from `sentence.start` in the same sentences.json)
   - `label` (optional): for your own notes; passed through
3. **Run `resolve_phrases`** to convert phrase→timing.
4. **Pipe to `build_timeline`** to emit the xmeml.

```bash
resolve_phrases cuts_phrases.json - | build_timeline - rough.xml
```

## Input format

```json
{
  "name": "My Rough Cut",
  "tracks": {
    "V1": [
      {
        "source": "/abs/path/interview1.mp4",
        "phrase": "the new system handles the load",
        "near": 245.6,
        "label": "Beat 1"
      },
      {"gap": 0.6},
      {
        "source": "/abs/path/interview2.mp4",
        "phrase": "It saved us several days per site.",
        "near": 78.2
      }
    ],
    "V2": [
      {"timeline_start": 2.5, "duration": 7.5, "source": "/abs/path/broll.mp4", "source_in": 4.0}
    ]
  }
}
```

Bare list and `{name, segments: [...]}` shapes work too — same shapes `build_timeline` accepts. Time-based segments (`start/duration`, `timeline_start`, `gap`) pass through unchanged.

### Phrase-segment fields

| Field | Required | Notes |
|---|---|---|
| `source` | yes | Absolute path; tool reads `<source-stem>.transcript.words.json` next to it. |
| `phrase` | yes | **Byte-identical** to a contiguous span of `.transcript.sentences.json`. Punctuation matters (`"system,"` ≠ `"system"`). Single space between words — multiple spaces fail. |
| `near` | yes | Start time of the first sentence the phrase touches. Used to disambiguate when the same phrase recurs. |
| `window` | no | Per-segment override of `--window` (half-window, ±seconds). Default 10s — covers typical sentence drift. Lower for dense Q&A; raise for very long sentences. |
| `label` | no | Passes through; useful for review. |

## CLI

```bash
resolve_phrases [--window SECONDS] <input.json> [output.json]
resolve_phrases update
```

- Default `--window`: 10 seconds.
- `<input.json>` accepts `-` for stdin; `[output.json]` accepts `-` for stdout.
- Without an explicit output, `foo.json` → `foo.resolved.json`.
- `update` self-updates the tool and skill.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `phrase not found in <file>: '...'` | Phrase isn't byte-identical to the words.json tokens — usually missing/extra punctuation, contraction differences (`don't` vs `do n't`), or copied from elsewhere | Re-copy verbatim from `.transcript.sentences.json` |
| `ambiguous phrase ... multiple matches near=N within disambiguation threshold` | Same phrase occurs more than once within the near-window | Either narrow the phrase (more unique words) or narrow `window` for that segment |
| `phrase {...} found Nx ... but none within near=X ±Ws` | The `near` is wrong — the phrase exists in the file but not where the operator expected | Check that `near = sentence.start` of the right sentence; widen `--window` if needed |
| `transcript not found at <path>` | No `.transcript.words.json` next to the source | Run `transcribe <source>` first |
| `phrase requires near` / `near requires phrase` | Missing field in segment | Author both, or remove both |
| `phrase is mutually exclusive with start/duration/...` | Segment mixes phrase-based and time-based fields | Pick one mode per segment |

## Authoring tips

- **Copy, don't type.** Open `.transcript.sentences.json` and copy `sentence` text directly; it preserves the exact tokenization Whisper produced.
- **Keep `near` as the sentence's `start`** even if the phrase is a sub-phrase. The 10s default window absorbs sentence-internal drift.
- **For phrases spanning two sentences,** use the start of the first sentence as `near`. Phrase must still be contiguous in the joined-words string (the space between sentences in `.sentences.json` is just a single space, so contiguous phrases work).
- **The audit field** (`_resolve_phrases`) on resolved segments preserves `phrase`, `near`, `anchor`, and a hash of the words.json so re-resolves can detect transcript regeneration. `build_timeline` ignores it.

## Do NOT

- Don't paraphrase. The matching is strict; even a single missing comma breaks it. The error is loud, but loud errors are still errors.
- Don't use this for B-roll. Time-based segments pass through unchanged — you don't need this tool for them.
- Don't try `near=0` as a "find anywhere" — there's no wildcard mode. If you actually want first-occurrence, use `--window` large enough to cover the file (or just use a time-based segment after spot-checking).
