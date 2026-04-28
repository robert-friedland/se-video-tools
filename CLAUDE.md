# se-video-tools

CLI tools for compositing iPad screen recordings over real-life background video, adding bezels, and syncing audio/video via clap detection.

## Tools

- **`composite_bezel.sh`** — shell wrapper for GPU compositing via `composite_bezel_gpu` binary (Apple Silicon only)
- **`composite_bezel_gpu/`** — Swift CLI (AVFoundation + Core Image/Metal); video-only output, shell does audio mux
- **`ipad_bezel.sh`** — add iPad bezel overlay to a standalone screen recording
- **`sync_clap.sh`** — detect clap sync offset between background and screen recording
- **`elevenlabs_tts.sh`** — ElevenLabs TTS with char/word/sentence timings; outputs mp3 + json + words/sentences SRTs
- **`transcribe.sh`** — local whisper.cpp transcription; word/sentence timings + interview classifier
- **`build_timeline.sh`** — JSON cut list → DaVinci Resolve-compatible Final Cut Pro 7 XML (xmeml v5). ffprobes each source for frame rate, resolution, audio channels, and embedded SMPTE timecode. Timecode round-trip is the critical constraint: Resolve validates `<file><timecode>` against the media's real embedded TC, so placeholder `00:00:00:00` breaks import when the source actually carries a TC. FCPXML 1.10 is rejected by Resolve — do not substitute.
- **`resolve_phrases.sh`** — phrase-based JSON cut list → time-based JSON. Reads `.transcript.words.json` next to each source, finds the verbatim phrase as a contiguous run of word tokens, picks the occurrence closest to `near`, emits exact word-level `start`/`duration`. Pipes into `build_timeline`.
- **`bridge_broll.sh`** — pad V1 cuts and generate a contiguous V2 b-roll track from a per-beat shot plan. Sits between `resolve_phrases` and `build_timeline`. V2 segments transition at the midpoint of each V1 gap so gaps are fully covered. Within each beat, shots distribute proportionally and are capped by `source_dur − source_in − v2_clearance`. Errors loudly when a beat's source budget is below its V2 span.

## Environment variables

- `ELEVENLABS_API_KEY` — required for `elevenlabs_tts`. Free tier (TTS-only) is fine; the tool reports quota after each run.

## Key flags (composite_bezel.sh / composite_bezel_gpu)

```
composite_bezel.sh <bg.mp4> <scr.mp4> <output.mp4> [options]

--bg-start <s>        Start offset into background (default: 0)
--scr-start <s>       Start offset into screen recording (default: 0)
--duration <s>        Render N seconds (default: shorter of the two clips)
--overlay-scale <f>   iPad height as fraction of output height (default: 0.7)
--margin <px>         Right/left edge margin (default: 40)
--x / --y <px>        Explicit overlay position
--output-width <px>   Scale output to this width (e.g. 1920)
--audio <mode>        both|bg|screen|none (default: both)
--bg-rotation <deg>   Override bg rotation: 0/90/180/270 (auto-detected if omitted)
--scr-rotation <deg>  Override scr rotation: 0/90/180/270 (auto-detected if omitted)
```

## Building composite_bezel_gpu

Must use Xcode toolchain (not CommandLineTools) due to SDK mismatch:

```bash
cd composite_bezel_gpu
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build -c release \
  -Xswiftc "-sdk" -Xswiftc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
```

Binary lands at `.build/release/composite_bezel_gpu`. Copy to `../composite_bezel_gpu_bin` for install.sh to pick up.

SourceKit SDK warnings in the editor are expected and harmless — the binary builds correctly.

## Architecture: composite_bezel_gpu

Two-pass pipeline:
1. **Swift binary** — GPU compositing via CIImage/Metal, outputs video-only MP4 (HEVC/hvc1)
2. **ffmpeg pass** — muxes audio from original source files via `atrim` + `amix`

Key coordinate system note: `AVAssetTrack.preferredTransform` is UIKit (Y-down). CIImage is Y-up. For 90°/270° rotations, applying UIKit transforms directly in CIImage space produces a 180° error — `applyRotation()` compensates via `atan2` detection. `applyExplicitRotation()` is used when `--bg-rotation`/`--scr-rotation` overrides are given (no Y-axis conversion needed).

## Bezel PNGs

Both shell scripts auto-detect the iPad model from screen-recording aspect ratio (long/short, ±2%) and pick the matching bezel; `--ipad mini|a16` overrides. Swift binary loads the PNG and looks up `BezelSpec` by pixel size — the PNG dimensions are the discriminator.

| Model    | PNG                                       | Bezel size | Cutout (top-left) | Cutout size | Long/short |
|----------|-------------------------------------------|------------|-------------------|-------------|------------|
| iPad mini| `iPad mini - Starlight - Portrait.png`    | 1780×2550  | x=146, y=142      | 1488×2266   | 1.5228     |
| iPad A16 | `iPad (A16) - Silver - Portrait.png`      | 2040×2760  | x=200, y=200      | 1639×2360   | 1.4390     |

`BezelSpec.knownSpecs` in `DimensionCalc.swift` is the authoritative table — adding a new bezel = one entry plus the PNG in `assets/`. Each spec includes `inflate=4` px of seam-hiding slop hidden behind the bezel chassis (replaces the legacy `scale=0.89` magic constant).

## Performance

~2× real-time on Apple Silicon. 16 min of 4K HEVC encodes in ~8 minutes.

## Test videos

- Background: `~/Downloads/IDEXX Closeout/PC1 Laser Line - fixed 3rd person.MP4` (4K, 18m38s, −180° rotation)
- Screen: `~/Downloads/IDEXX Closeout/PC1 Laser Line - screen recording.MP4` (1920×1260 encoded, −90° rotation → 1260×1920 display, 19m10s)
- Audio sync point: `--scr-start 191` (3:11) aligns clap in both clips

## GitHub

Repo: `robert-friedland/se-video-tools`
Binary attached to GitHub Releases as `composite_bezel_gpu` (downloaded by `install.sh` and `composite_bezel update`)

## Release checklist

When cutting a new release (or after merging any PR that changes Swift source):

1. Build the binary (see "Building composite_bezel_gpu" above)
2. Upload to the release:
   ```bash
   gh release upload <tag> composite_bezel_gpu_bin -R robert-friedland/se-video-tools
   ```
   Or via the GitHub UI: Releases → edit the release → attach the binary.
3. Verify the asset is present:
   ```bash
   gh release view <tag> -R robert-friedland/se-video-tools --json assets
   ```
   The `assets` array must be non-empty. If empty, `composite_bezel update` will warn that the
   download failed (but will preserve any existing local binary — it no longer corrupts it).
