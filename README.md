# se-video-tools

Shell tools for compositing iPad screen recordings with a realistic bezel overlay, syncing footage, and producing polished demo videos.

## Prerequisites

- macOS Apple Silicon (M1 or later)
- [Homebrew](https://brew.sh) — installed automatically if missing
- ffmpeg — installed automatically via Homebrew

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/robert-friedland/se-video-tools/main/install.sh | bash
```

This installs `ipad_bezel`, `composite_bezel`, and `sync_clap` into `~/.se-video-tools/` and symlinks them into your Homebrew bin so they're on your PATH immediately. If [Claude Code](https://claude.ai/code) is installed, the `/ipad-bezel`, `/composite-bezel`, `/sync-clap`, `/sync-visual`, and `/se-video-tools` skills are also installed.

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

### `/sync-visual` (Claude Code skill)

Interactively syncs two videos when there is no clap — or when you want to sync on a specific on-screen event. Claude extracts frames in a coarse-to-fine sweep, visually identifies the matching event in both clips, and outputs `--bg-start` / `--scr-start` offsets. Expect several rounds of frame extraction and review before a final offset is produced.

Requires [Claude Code](https://claude.ai/code). Invoke with `/sync-visual` in a Claude Code session.

---

## Updating

```bash
se-video-tools update
```

Updates `ipad_bezel`, `composite_bezel`, `sync_clap`, and the `se-video-tools` dispatcher. Also refreshes Claude Code skills when the `~/.claude/commands` directory is present.

Or update individual tools:

```bash
ipad_bezel update
composite_bezel update
sync_clap update
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
| `/se-video-tools` | Update all tools |
