Detect a sync clap in two video files and produce `--bg-start` / `--scr-start` offsets for `composite_bezel`, then composite the clips.

## Your job when this skill is invoked

1. If the user hasn't provided both files, ask: "Which file is the background and which is the screen recording?"
2. Ask about `--search-start` / `--search-end` only if the user says the clap isn't near the start of both clips, or if a previous run warned about no clear transient.
3. Run `sync_clap` and capture its output (use the Bash tool and capture stdout).
4. Check the output for any `WARN:` lines. If any are present, show the user the warning and ask whether to continue before running `composite_bezel`. Do not silently proceed.
5. Parse the `SYNC bg=N scr=N` line from the output. Extract the two values using a regex or awk — the format is always `SYNC bg=<float> scr=<float>`.
6. Pass those values directly to `composite_bezel` without asking the user to re-enter them.
7. Report the final output path, file size, and duration.

## Command

```bash
sync_clap [--search-start N] [--search-end N] "<background>" "<screen_recording>"
```

Options:
- `--search-start N` — seconds into both clips to begin looking for the clap (default `0`)
- `--search-end N` — seconds into both clips to stop looking (default `30`). The clap must be within this window; use a tight range if there is ambient noise before the clap.

## Output parsing

The `SYNC` line format is fixed: `SYNC bg=<float> scr=<float>` (e.g., `SYNC bg=2.314 scr=0.892`). Parse it with:

```bash
SYNC_LINE=$(echo "$OUTPUT" | grep '^SYNC')
BG_START=$(echo "$SYNC_LINE" | sed 's/SYNC bg=\([^ ]*\) scr=.*/\1/')
SCR_START=$(echo "$SYNC_LINE" | sed 's/SYNC bg=[^ ]* scr=\([^ ]*\)/\1/')
```

Then run:

```bash
composite_bezel --bg-start "$BG_START" --scr-start "$SCR_START" "<background>" "<screen_recording>"
```

## Key facts

- Both clips must have audio. If either lacks an audio stream the tool will error before extracting anything.
- The `--bg-start`/`--scr-start` values are absolute trim points into each file, not a relative offset. Both clips will start playing from their respective clap moments, so they align going forward.
- The algorithm finds the **first prominent transient** (earliest energy onset above 50% of the loudest rise) within the search window. A loud sound before the clap inside the window can cause a false positive — use `--search-start` to skip past any pre-roll noise.
- Per-clip search windows are not supported in v1. Both clips share the same `--search-start`/`--search-end`.
- To update the tool: `sync_clap update`

## Typical workflow

```
sync_clap "background.mp4" "screen.mp4"
→ parses SYNC line, runs composite_bezel automatically
```

If a `WARN:` line appears (no clear transient found), narrow the search window:

```
sync_clap --search-start 2 --search-end 10 "background.mp4" "screen.mp4"
```
