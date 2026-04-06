Composite a screen recording (with iPad mini bezel, floating transparently) over real-life background footage, producing a single MP4 ready for editing in DaVinci Resolve.

## Your job when this skill is invoked

1. If the user hasn't specified both files, ask: "Which file is the background (real-life footage) and which is the screen recording?"
2. If they haven't specified an output path, the default (`<background>_composite.mp4` in the same directory) is fine — no need to ask.
3. Run the command via Bash and wait for it to finish.
4. Report the output path, file size, and duration.

## Command

```bash
composite_bezel "<background_file>" "<screen_recording>" ["<output_file>"]
```

Optional flags:
- `--overlay-scale 0.7` — size of the bezeled iPad as a fraction of background height (default 0.7)
- `--margin 40` — pixel gap between the right edge of the overlay and the right edge of the frame (default 40)
- `--test-seconds N` — limit processing to first N seconds (useful for quick test renders)

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
