Generate a DaVinci Resolve-compatible timeline (Final Cut Pro 7 XML / xmeml v5) from a JSON cut list. Each segment names a source MP4, an in-point (seconds), and a duration. The tool probes each source for frame rate, resolution, audio channels, and embedded SMPTE timecode, then emits xmeml that Resolve will import with all media linked automatically. **Use this when the user wants an assembled rough cut they can open in Resolve, not a rendered video file.**

**TRIGGER** on any of these — keyword match is enough:
- **"build a timeline"**, **"make a timeline"**, **"assemble a timeline"**, **"generate a timeline"**, **"cut list"**, **"rough cut"**, **"assembly edit"**, **"paper edit"** pointed at multiple source clips
- **"DaVinci Resolve timeline"**, **"import into Resolve"**, **"open in Resolve"**, **"edit in Resolve"** where the user doesn't already have the timeline built
- **"FCPXML"**, **"xmeml"**, **"FCP7 XML"**, **"Final Cut Pro XML"** — any request for an NLE interchange file
- The user asks you to splice quotes from multiple interviews into a single sequence for review
- Any plan that would otherwise call `ffmpeg -f concat` just to let the user review cuts in an editor — stop, produce a timeline instead so trims are non-destructive

**SKIP** (different tools or no tool needed):
- Rendering / encoding a final video file → use `ffmpeg` directly
- Trimming a single clip with no assembly needed → `ffmpeg` or direct editor work
- Color grading, VFX, titles, transitions — this tool only produces straight-cut assembly edits
- Text-to-speech narration → `/elevenlabs-tts`
- Finding quotes inside interviews → `/transcribe` first to get `.sentences.json`, then this tool for the assembly

## Typical workflow

1. `/transcribe` the interview folder to get `.transcript.sentences.json` per clip.
2. Scan the sentences files and pick quotes with their start/end timestamps.
3. Build the JSON cut list (see "Input format" below).
4. Run `build_timeline cut.json rough.xml`.
5. Tell the user to import `rough.xml` into Resolve via `File → Import → Timeline…`. Resolve will auto-link the source MP4s.

## Input format

Array form — simplest:

```json
[
  {"source": "/abs/path/interview1.mp4", "start": 57.60, "duration": 12.40, "label": "Beat 1"},
  {"gap": 0.60},
  {"source": "/abs/path/interview2.mp4", "start": 234.84, "duration": 10.16}
]
```

Object form — lets you set the sequence name in the file:

```json
{
  "name": "My Rough Cut",
  "segments": [ /* ... same as array form ... */ ]
}
```

Fields:
- `source` — absolute path to a video file (MP4, MOV, etc.) readable by ffprobe
- `start` — seconds into the source where the clip begins (float)
- `duration` — seconds to take from that source
- `label` — optional; Resolve ignores it on import but it's useful in the JSON for review
- `gap` — seconds of empty timeline before the next clip (use sparingly; editors prefer to add room tone themselves)

Use absolute paths. Relative paths will confuse Resolve's media linking.

## Command

```bash
build_timeline [--name NAME] <input.json> [output.xml]
build_timeline update
```

- Without `output.xml`, derives `foo.json` → `foo.xml`.
- `-` in either position means stdin/stdout, so you can pipe JSON in.
- `--name` sets the sequence name. If the JSON's object form specifies `name`, that wins.

## Key facts — internalize these before generating a cut list

- **Timecodes matter.** Resolve validates the `<file><timecode>` entry in xmeml against the media's real embedded SMPTE TC. The tool handles this via ffprobe. If a source *genuinely* has no embedded TC, the tool falls back to `00:00:00:00` and prints a warning. If that warning appears and Resolve still reports "clips not found" on import, the source likely *does* have TC but ffprobe missed it — inspect with `ffprobe -show_entries stream_tags=timecode` directly.
- **One frame rate per timeline.** All sources must share one r_frame_rate. If they don't, the tool exits with a message naming the two offending sources. Conform the odd one out with ffmpeg before retrying.
- **One resolution per timeline.** Same rule. Mixed resolutions would need a conform pass.
- **The output is assembly-only.** No transitions, no effects, no color work. Those live in the editor. This tool exists to get you out of ffmpeg-concat purgatory and into a real NLE.
- **`build_timeline update`** refreshes the tool and this skill file.

## Failure modes and diagnoses

| Symptom | Cause | Fix |
|---|---|---|
| Resolve: "5 of 5 clips were not yet found" | Source TC in xmeml doesn't match embedded media TC | Run the tool; it reads real TCs. If still failing, re-run `ffprobe` on each source manually and confirm the TC is what the xmeml shows. |
| Tool exits with "frame rate mismatch" | One source is e.g. 25 fps, another 29.97 | Transcode the odd source: `ffmpeg -i src.mp4 -r 29.97 src_29.97.mp4`. Then update the JSON. |
| Tool exits with "resolution mismatch" | One source is 4K, another 1080p | Conform: `ffmpeg -i 4k.mp4 -vf "scale=1920:1080" 4k_1080.mp4`. |
| `warning: N source(s) have no embedded SMPTE timecode` | DJI/iPhone clips usually have TC; screen recordings usually don't | If import still works, ignore. If not, verify with `ffprobe -show_entries stream_tags=timecode <path>`. |

## Do NOT

- Render the video yourself with `ffmpeg -f concat` when the user wants an editable timeline. The timeline stays non-destructive; a rendered file doesn't.
- Generate FCPXML 1.10 — Resolve silently rejects the media links. This tool emits xmeml v5 (Final Cut Pro 7 XML) because that's what Resolve round-trips cleanly.
- Hand-author xmeml. The timecode, frame rate, and clip-id math is fiddly and Resolve is strict about all three.
- Skip the absolute-path requirement. Relative paths in xmeml make Resolve treat every clip as missing.
