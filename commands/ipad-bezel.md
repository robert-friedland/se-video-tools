Add an iPad mini Starlight bezel overlay to a screen recording, producing an MP4 ready for editing in DaVinci Resolve.

## Your job when this skill is invoked

1. If the user hasn't specified a file, ask which screen recording they want to bezel.
2. If they haven't specified an output path, the default (`<input>_bezeled.mp4` in the same directory) is fine — no need to ask.
3. Run the command via Bash and wait for it to finish.
4. Report the output path, file size, and duration.

## Command

```bash
ipad_bezel "<input_file>" ["<output_file>"]
```

## Key facts

- Input must be a portrait iPad mini screen recording. The script validates the aspect ratio and will warn if it doesn't look right.
- Rotation metadata is handled automatically — recordings encoded sideways (common with iOS) work fine.
- Processing runs in parallel across all CPU cores and takes roughly half the video's duration.
- Output is HEVC MP4 tagged for QuickTime and DaVinci Resolve compatibility.
- To update the tool: `ipad_bezel update`

## Workflow context

This tool is used by SEs to pre-process screen recordings for POC sizzle reels before bringing them into DaVinci Resolve for editing. The bezeled file is an editing intermediate — it does not need to be final quality.
