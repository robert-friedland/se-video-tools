Composite a screen recording (with iPad mini bezel, floating transparently) over real-life background footage, producing a single MP4 ready for editing in DaVinci Resolve.

## Your job when this skill is invoked

1. If the user hasn't specified both files, ask: "Which file is the background (real-life footage) and which is the screen recording?"
2. If they haven't specified an output path, the default (`<background>_composite.mp4` in the same directory) is fine — no need to ask.
3. Ask about `--bg-start`, `--scr-start`, and `--duration` only if the user mentions wanting a specific clip range, trimming, or timing alignment between the two clips.
4. Ask about `--audio` only if the user mentions audio preferences (e.g. "only use the screen audio", "mute the background").
5. Use `--x`/`--y` only if the user requests a specific overlay position; otherwise the default (right side, vertically centered) is fine.
6. Run the command via Bash and wait for it to finish.
7. Report the output path, file size, and duration.

## Command

```bash
composite_bezel [OPTIONS] "<background_file>" "<screen_recording>" ["<output_file>"]
```

Optional flags:

**Layout:**
- `--overlay-scale 0.7` — size of the bezeled iPad as a fraction of background height (default `0.7`)
- `--margin 40` — pixel gap between the right edge of the overlay and the right edge of the frame; ignored if `--x` is set (default `40`)
- `--x N` — explicit X pixel position of the overlay's left edge (overrides `--margin`)
- `--y N` — explicit Y pixel position of the overlay's top edge (default: vertically centered)

**Timing:**
- `--bg-start N` — start time in seconds to trim into the background clip (default `0`)
- `--scr-start N` — start time in seconds to trim into the screen recording (default `0`)
- `--duration N` — output duration in seconds; defaults to the shorter of the two remaining clip lengths. `--test-seconds N` is an alias.

**Audio:**
- `--audio both|bg|screen|none` — which audio to include in the output (default `both`). `both` mixes background + screen audio at equal levels; `bg` and `screen` use a single source; `none` strips audio entirely.

## Key facts

- The screen recording must be a portrait iPad mini recording. Aspect ratio is validated automatically.
- The background should be landscape footage. A warning is shown if it is not.
- The bezeled iPad floats transparently over the background — no solid color box around it.
- Rotation metadata on either input is handled automatically.
- Processing runs in parallel across all CPU cores.
- Output is HEVC MP4 tagged for QuickTime and DaVinci Resolve compatibility.
- To update the tool: `composite_bezel update`

## Workflow context

Use this tool when you have a "talking hands" or product demo clip where the SE is working in person, and you want to overlay the screen recording on top of the real-life footage for a sizzle reel. If you want just the bezeled recording without a background, use `/ipad-bezel` instead.
