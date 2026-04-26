# se-video-tools

Shell tools for compositing iPad screen recordings with a realistic bezel overlay, syncing footage, and producing polished demo videos.

## Prerequisites

- macOS Apple Silicon (M1 or later)
- [Homebrew](https://brew.sh) — installed automatically if missing
- ffmpeg — installed automatically via Homebrew
- whisper-cpp — installed automatically via Homebrew (for `transcribe`)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/robert-friedland/se-video-tools/main/install.sh | bash
```

This installs `ipad_bezel`, `composite_bezel`, `sync_clap`, and friends into `~/.se-video-tools/` and symlinks them into your Homebrew bin so they're on your PATH immediately. If [Claude Code](https://claude.ai/code) is installed, the matching skills are also installed (see the Claude Code skills table at the bottom).

---

## Tools

### `ipad_bezel`

Overlays an iPad mini Starlight bezel on a screen recording. Produces a single MP4 ready for editing.

```bash
ipad_bezel [--bg black|greenscreen|0xRRGGBB] [--duration N] input.mp4 [output.mp4]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--bg` | `black` | Background color behind the bezel. Use `greenscreen` for chroma-key green. |
| `--duration N` | full clip | Render N seconds of output. |

```bash
ipad_bezel recording.mp4
ipad_bezel --bg greenscreen recording.mp4 recording_keyed.mp4
ipad_bezel --duration 30 recording.mp4
```

---

### `composite_bezel`

Composites a screen recording (with bezel, floating transparently) over a real-life background video. GPU-accelerated on Apple Silicon. Screen recordings are automatically detected and converted from variable frame rate (VFR) to constant frame rate before compositing.

```bash
composite_bezel [OPTIONS] background.mp4 screen_recording.mp4 [output.mp4]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--overlay-scale N` | `0.7` | iPad height as a fraction of background height. |
| `--x N` / `--y N` | right-center | Pixel position of the iPad overlay. |
| `--margin N` | `40` | Right-edge gap when `--x` is not set. |
| `--bg-start N` | `0` | Start offset in seconds for background clip. |
| `--scr-start N` | `0` | Start offset in seconds for screen recording. |
| `--duration N` | min of clips | Render this many seconds of output. |
| `--audio both\|bg\|screen\|none` | `both` | Which audio to include. |
| `--output-width N` | native | Scale output to this width (e.g. `1920` for 1080p). |
| `--bg-rotation N` | auto | Override background rotation: `0`, `90`, `180`, or `270`. |
| `--scr-rotation N` | auto | Override screen recording rotation: `0`, `90`, `180`, or `270`. |

```bash
composite_bezel bg.mp4 screen.mp4
composite_bezel --overlay-scale 0.6 --margin 60 --audio bg bg.mp4 screen.mp4 out.mp4
composite_bezel --bg-start 5 --scr-start 2 --duration 30 bg.mp4 screen.mp4
```

---

### `sync_clap`

Detects the clap-board sync point between a background camera and a screen recording by finding the audio transient peak in each. Prints `--bg-start` / `--scr-start` offsets ready to paste into `composite_bezel`.

```bash
sync_clap background.mp4 screen_recording.mp4
```

---

### `elevenlabs_tts`

Generates narration audio via the ElevenLabs API with per-character, per-word, and per-sentence timings. Outputs an mp3 plus split JSON files (`.sentences.json`, `.words.json`, plus a combined `.json` with everything) and two SRTs for Resolve import. Split files let downstream tools load only the granularity they need — pair sentences with `/analyze-video` to match narration beats to background footage. Requires `ELEVENLABS_API_KEY` env var; free-tier TTS-only accounts work.

```bash
elevenlabs_tts [OPTIONS] "text" | --text-file path.txt
```

| Flag | Default | Description |
|------|---------|-------------|
| `--voice NAME_OR_ID` | `Chris` | Built-in name (Chris, Rachel, Adam, …) or 20-char raw voice_id. `--list-voices` prints the map. |
| `--model ID` | `eleven_multilingual_v2` | Also supports `eleven_turbo_v2_5`, `eleven_flash_v2_5`. |
| `--stability 0..1` | `0.5` | Lower = more expressive, higher = more consistent. |
| `--similarity 0..1` | `0.75` | similarity_boost. |
| `--style 0..1` | `0.0` | Style exaggeration. |
| `--speed 0.7..1.2` | `1.0` | voice_settings.speed. |
| `--no-speaker-boost` | off | Disables use_speaker_boost. |
| `--format FMT` | `mp3_44100_128` | Passed through as `?output_format=`. |
| `--text-file PATH` | — | Read narration from file. |
| `--out PREFIX` | derived | Output basename. Without `--out`, auto-suffixes `_1`, `_2`, … on collision. |
| `--audio-only` | off | Skip JSON + SRTs; write only `.mp3`. |
| `--force` | off | Overwrite existing artifacts. |

```bash
elevenlabs_tts "Welcome to the demo. Today we'll see the new interface."
elevenlabs_tts --voice Rachel --out intro "This is Rachel narrating."
```

---

### `transcribe`

Local speech-to-text via [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Runs offline — no API key, no credits. Produces word-level and sentence-level timings alongside each video, plus a `likely_interview` classifier flag so you can filter a folder of mixed interview / b-roll footage to just the clips worth searching for quotes. Models auto-download to `~/.whisper-models/` on first use.

```bash
transcribe <video-or-folder> [OPTIONS]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--model NAME_OR_PATH` | `large-v3-turbo` | Short name (`tiny.en`, `base.en`, `small.en`, `medium.en`, `large-v3`, `large-v3-turbo`) or explicit `.bin` path. |
| `--language CODE` | `en` | Language hint. Use `auto` for detection. |
| `--ext LIST` | `mp4,mov,m4v,mkv,MP4,MOV,M4V,MKV,wav,mp3` | Extensions to process in folder mode. |
| `--min-words N` | `30` | Real-word threshold for `likely_interview` flag. |
| `--threads N` | whisper default | Threads for `whisper-cli`. |
| `--prompt TEXT` | neutral punctuated hint | Initial prompt passed to Whisper; biases output toward punctuation/capitalization (prompt text never appears in transcript). |
| `--no-prompt` | off | Disable the default initial prompt. |
| `--force` | off | Overwrite existing outputs. |
| `--keep-wav` | off | Keep the extracted 16 kHz WAV next to the video. |

For each `<video>`, writes: `<video>.transcript.json` (combined + summary), `<video>.transcript.words.json`, `<video>.transcript.sentences.json`, matching `.srt` files, and `.transcript.txt`.

```bash
transcribe ~/Onsites/2026-04-idexx                      # batch: every video in the folder
transcribe "Brian Interview.MP4"                        # single file
transcribe --model small.en --language auto clip.mov    # smaller model, auto language
```

---

### `build_timeline`

Generate a DaVinci Resolve-compatible Final Cut Pro 7 XML (xmeml v5) timeline from a JSON cut list. Each segment names a source video, an in-point (seconds), and a duration; the tool ffprobes each source for frame rate, resolution, audio channels, and embedded SMPTE timecode, then emits xmeml that Resolve imports with all media linked automatically. Useful for turning a scanned-transcripts quote list into a rough cut you can trim in an NLE instead of re-rendering from ffmpeg.

```bash
build_timeline [--name NAME] <input.json> [output.xml]
```

**Single-track input** — array form:

```json
[
  {"source": "/abs/path/interview1.mp4", "start": 57.60, "duration": 12.40, "label": "Beat 1"},
  {"gap": 0.60},
  {"source": "/abs/path/interview2.mp4", "start": 234.84, "duration": 10.16}
]
```

Or object form with a sequence name:

```json
{ "name": "My Rough Cut", "segments": [ /* ... */ ] }
```

**Multi-track input** — V1 talking heads + V2 B-roll overlay. V1 uses the sequential format above; V2+ uses absolute timeline positions and is video-only (V1 audio plays continuously underneath, V2 covers V1 video as full-frame replacement):

```json
{
  "name": "My Rough Cut v2",
  "tracks": {
    "V1": [
      {"source": "/abs/interview1.mp4", "start": 57.60, "duration": 12.40, "label": "Beat 1"},
      {"gap": 0.60},
      {"source": "/abs/interview2.mp4", "start": 234.84, "duration": 10.16}
    ],
    "V2": [
      {"timeline_start": 2.50, "duration": 7.50, "source": "/abs/broll.mp4", "source_in": 4.0, "label": "Beat 1 overlay"}
    ]
  }
}
```

V2+ segments use `timeline_start` (absolute seconds) instead of sequential placement; there's no `gap` on V2+. Currently supports V1 and V2; V3+ would extend the same pattern. Schema is also limited to a single audio track derived from V1.

| Flag | Default | Description |
|------|---------|-------------|
| `--name NAME` | input basename | Sequence name embedded in the XML. Ignored if the JSON object has `name`. |

All sources on a given timeline must share one frame rate and one resolution; mismatches are rejected with a message naming the offender. Import the resulting `.xml` into Resolve via `File → Import → Timeline…`.

```bash
build_timeline cut.json rough.xml
echo '[{"source":"/abs/clip.mp4","start":0,"duration":10}]' | build_timeline - -
```

---

### `/sync-visual` (Claude Code skill)

Interactively syncs two videos when there is no clap — or when you want to sync on a specific on-screen event. Claude extracts frames in a coarse-to-fine sweep, visually identifies the matching event in both clips, and outputs `--bg-start` / `--scr-start` offsets. Expect several rounds of frame extraction and review before a final offset is produced.

Requires [Claude Code](https://claude.ai/code). Invoke with `/sync-visual` in a Claude Code session.

---

## Updating

```bash
se-video-tools update
```

Updates `ipad_bezel`, `composite_bezel`, `sync_clap`, `extract_frames`, `elevenlabs_tts`, `transcribe`, `build_timeline`, and the `se-video-tools` dispatcher. Also refreshes Claude Code skills when the `~/.claude/commands` directory is present.

Or update individual tools:

```bash
ipad_bezel update
composite_bezel update
sync_clap update
elevenlabs_tts update
transcribe update
build_timeline update
```

---

## Claude Code skills

The installer adds the following skills when Claude Code is detected:

| Skill | Description |
|-------|-------------|
| `/ipad-bezel` | Run `ipad_bezel` from a Claude Code session |
| `/composite-bezel` | Run `composite_bezel` from a Claude Code session |
| `/sync-clap` | Run `sync_clap` from a Claude Code session |
| `/sync-visual` | Interactively find sync offsets using Claude's vision (no clap required) |
| `/elevenlabs-tts` | Generate ElevenLabs narration with word/sentence timings |
| `/transcribe` | Local Whisper transcription with word/sentence timings and interview-vs-b-roll classifier |
| `/build-timeline` | Generate a DaVinci Resolve-compatible xmeml timeline from a JSON cut list |
| `/se-video-tools` | Update all tools |
