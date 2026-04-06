# se-video-tools

Shell tools for compositing iPad screen recordings with a realistic bezel overlay, syncing multi-camera clap boards, and producing polished demo videos.

## Prerequisites

- macOS (Apple Silicon or Intel)
- [Homebrew](https://brew.sh) — installed automatically if missing
- ffmpeg — installed automatically via Homebrew

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/robert-friedland/se-video-tools/main/install.sh | bash
```

This installs three commands — `ipad_bezel`, `composite_bezel`, and `sync_clap` — into `~/.se-video-tools/` and symlinks them into your Homebrew bin so they're on your PATH immediately.

---

## Tools

### `ipad_bezel`

Overlays an iPad mini Starlight bezel on a screen recording. Produces a single MP4 ready for editing.

```bash
ipad_bezel [--bg black|greenscreen|0xRRGGBB] [--jobs N] input.mp4 [output.mp4]
```

**Options**

| Flag | Default | Description |
|------|---------|-------------|
| `--bg` | `black` | Background color behind the bezel. Use `greenscreen` for chroma-key green. |
| `--jobs N` | all CPUs | Number of parallel render chunks. |

**Examples**

```bash
ipad_bezel recording.mp4
ipad_bezel --bg greenscreen recording.mp4 recording_keyed.mp4
ipad_bezel --jobs 4 recording.mp4
```

---

### `composite_bezel`

Composites a screen recording (with bezel, floating transparently) over a real-life background video. The bezel has no solid background box — it blends naturally over the footage.

```bash
composite_bezel [OPTIONS] background.mp4 screen_recording.mp4 [output.mp4]
```

**Key options**

| Flag | Default | Description |
|------|---------|-------------|
| `--overlay-scale N` | `0.7` | iPad height as a fraction of background height. |
| `--x N` / `--y N` | right-center | Pixel position of the iPad overlay. |
| `--margin N` | `40` | Right-edge gap when `--x` is not set. |
| `--bg-start N` | `0` | Start time in seconds for background clip. |
| `--scr-start N` | `0` | Start time in seconds for screen recording. |
| `--duration N` | min of clips | Render this many seconds of output. |
| `--audio both\|bg\|screen\|none` | `both` | Which audio to include. |
| `--jobs N` | all CPUs | Number of parallel render chunks. |
| `--output-width N` | native | Scale output to this width (e.g. `1920` for 1080p). |

**Examples**

```bash
composite_bezel bg.mp4 screen.mp4
composite_bezel --overlay-scale 0.6 --margin 60 --audio bg bg.mp4 screen.mp4 out.mp4
composite_bezel --bg-start 5 --scr-start 2 --duration 30 bg.mp4 screen.mp4
```

---

### `sync_clap`

Detects the clap-board sync point between a background camera and a screen recording by finding the audio transient peak in each. Prints the time offset you need to apply in your editor.

```bash
sync_clap background.mp4 screen_recording.mp4
```

---

## Updating

Each tool has a built-in `update` subcommand that pulls the latest version from GitHub:

```bash
ipad_bezel update
composite_bezel update
sync_clap update
```

## Claude Code skills

If [Claude Code](https://claude.ai/code) is installed, the installer also adds `/ipad-bezel`, `/composite-bezel`, and `/sync-clap` skills so Claude can drive the tools directly from a chat prompt.
