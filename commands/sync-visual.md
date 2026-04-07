Visually sync two videos (background footage + iPad screen recording) by interactively finding a matching visual event in both, then producing `--bg-start` / `--scr-start` offsets for `composite_bezel`.

## Your job when this skill is invoked

1. Ask for the background video path and screen recording path if not already provided.
2. Set up a working directory with `mktemp -d` (or reuse `/tmp/vsync_frames/` if it exists).
3. Run a **coarse sweep** of both videos to find a distinctive visual event that appears in both.
4. **Narrow down** to 1-second precision, then to sub-second (0.2–0.3 s steps).
5. Emit a `SYNC bg=X scr=Y` line and offer to run `composite_bezel`.

Always show extracted frames to the user as you go — this is a live, interactive visual process. Do not try to automate the comparison; rely on your own vision to read the frames.

---

## Phase 1 — Setup

```bash
WORK=$(mktemp -d)
echo "Working in $WORK"
```

Get the total duration of both clips so you know the search space:

```bash
ffprobe -v error -show_entries format=duration -of csv=p=0 "BG_VIDEO"
ffprobe -v error -show_entries format=duration -of csv=p=0 "SCR_VIDEO"
```

---

## Phase 2 — Coarse sweep (5–10 s intervals)

Extract 16 evenly-distributed frames from each video across the first 2 minutes (or the full clip if shorter). Use fast seek — accuracy is not critical at this stage.

First get both durations, then clamp to 120 s:

```bash
BG_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "BG_VIDEO" | tr -d '[:space:]')
SCR_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "SCR_VIDEO" | tr -d '[:space:]')
BG_COARSE_STOP=$(echo "if ($BG_DUR < 120) $BG_DUR else 120" | bc -l)
SCR_COARSE_STOP=$(echo "if ($SCR_DUR < 120) $SCR_DUR else 120" | bc -l)

extract_frames "BG_VIDEO"  16 "$WORK" --start 0 --stop "$BG_COARSE_STOP"  --scale 400 --prefix bg_coarse
extract_frames "SCR_VIDEO" 16 "$WORK" --start 0 --stop "$SCR_COARSE_STOP" --scale 400 --prefix scr_coarse
```

With 16 frames over 120 s the half-step formula places the first frame at ~3.75 s (avoids the common black-frame at T=0) and spaces frames ~7.5 s apart.

Read and examine the frames (use the Read tool on each `.jpg`). Look for:
- An app tap that changes the screen (button press, page transition, modal opening)
- A step transition or slide change
- A loading spinner completing
- Any on-screen clock or timestamp if visible
- A physical gesture with a distinctive result (swipe, long-press menu appearing)

The background video shows the iPad at an angle on a workstation — the screen may be small. If you can see a screen change in the background frames, note the approximate background time. Find the matching event in the screen recording frames.

**Explain to the user what event you are using** before narrowing in.

---

## Phase 3 — Zoomed crop for the background video (if needed)

If the iPad screen is too small to read in the background frames, extract a full-resolution frame at a promising moment, then crop and zoom.

First, get a full frame to identify tablet screen coordinates (use accurate seek — `-i` before `-ss`):

```bash
ffmpeg -i "BG_VIDEO" -ss T -frames:v 1 -vf "scale=1920:-1" -q:v 2 "$WORK/bg_full_T.jpg" -y 2>/dev/null
```

Read that frame, estimate the bounding box of the iPad screen in the scaled image (convert to source 4K coords by multiplying by `SOURCE_WIDTH/1920`), then crop:

```bash
# Replace W H X Y with your estimated crop box in source-resolution pixels
ffmpeg -i "BG_VIDEO" -ss T -frames:v 1 -vf "crop=W:H:X:Y,scale=400:-1" -q:v 2 "$WORK/bg_crop_T.jpg" -y 2>/dev/null
```

Read the cropped frame. Adjust crop coordinates and repeat until the tablet screen is clearly legible.

---

## Phase 4 — Medium sweep (1 s intervals)

Once you have a ±5 s window around the event in each video, extract 10 evenly-distributed frames from that window using **accurate seek** to ensure frame-accurate positioning:

```bash
# Replace BG_LO / BG_HI with your coarse window for the background
# Replace W H X Y with your crop box (from Phase 3)
extract_frames "BG_VIDEO"  10 "$WORK" --start BG_LO --stop BG_HI --scale 400 --accurate --crop W:H:X:Y --prefix bg_med

# Replace SCR_LO / SCR_HI with your coarse window for the screen recording
extract_frames "SCR_VIDEO" 10 "$WORK" --start SCR_LO --stop SCR_HI --scale 400 --accurate --prefix scr_med
```

Read each frame in sequence. Narrow down to the 1-second bracket where the event occurs in each video (e.g. "event happens between t=42 and t=43 in the background, between t=17 and t=18 in the screen recording").

---

## Phase 5 — Fine sweep (0.2–0.3 s intervals)

Within the 1-second bracket for each clip, extract 6 frames over a 1.2 s window using accurate seek. Extending to 1.2 s ensures the half-step distribution covers the full bracket including the boundary.

Pre-evaluate stop times before passing to the script (the script accepts numeric values only):

```bash
# Replace BG_SEC / SCR_SEC with the integer seconds identified in Phase 4
BG_FINE_STOP=$(echo "BG_SEC + 1.2" | bc)
SCR_FINE_STOP=$(echo "SCR_SEC + 1.2" | bc)

extract_frames "BG_VIDEO"  6 "$WORK" --start BG_SEC --stop "$BG_FINE_STOP"  --scale 400 --accurate --crop W:H:X:Y --prefix bg_fine
extract_frames "SCR_VIDEO" 6 "$WORK" --start SCR_SEC --stop "$SCR_FINE_STOP" --scale 400 --accurate --prefix scr_fine
```

With 6 frames over a 1.2 s window the half-step formula produces timestamps at +0.1, +0.3, +0.5, +0.7, +0.9, +1.1 s — covering the full 1-second bracket and its boundary.

Read each frame. Pick the frame in each clip where the event **first becomes visible** (e.g. the first frame where the new screen state appears). Record:
- `BG_EVENT` = timestamp in background where the event is first visible (e.g. `42.4`)
- `SCR_EVENT` = timestamp in screen recording where the event is first visible (e.g. `17.6`)

---

## Phase 6 — Compute the sync offset

The sync offsets position both clips so that `BG_EVENT` and `SCR_EVENT` play at the same wall-clock time.

```
offset = SCR_EVENT - BG_EVENT
```

- If `offset >= 0`: screen recording started earlier than the background, or they started together.
  - `--bg-start 0 --scr-start <offset>`
- If `offset < 0`: background started earlier.
  - `--bg-start <abs(offset)> --scr-start 0`

Report the result in the standard format:

```
SYNC bg=<bg-start> scr=<scr-start>
Suggested command:
composite_bezel --bg-start <bg-start> --scr-start <scr-start> "BG_VIDEO" "SCR_VIDEO"
```

---

## Phase 7 — Offer to composite

Ask the user: "Ready to run composite_bezel with these offsets?"

If yes, run `composite_bezel` with the computed `--bg-start` and `--scr-start` values. Use the `/composite-bezel` skill for the compositing step — it will prompt for any remaining options.

---

## Key technical notes

**Fast seek vs. accurate seek:**
- Fast seek (default): use for coarse sweeps. May land on a nearby keyframe; can be off by several seconds. Fast but imprecise.
- Accurate seek (`--accurate` flag): use for medium and fine sweeps. Decodes from the previous keyframe; always lands on the exact frame. Slower but precise.

**`extract_frames` usage:**
```bash
extract_frames VIDEO N OUTPUT_DIR [--start S] [--stop S] [--scale PX] [--accurate] [--crop W:H:X:Y] [--prefix NAME]
```
Frames are named `{prefix}_{seq}_{timestamp}s.jpg`. Timestamps in filenames are the actual seek positions (one decimal place).

**Crop syntax:** `crop=W:H:X:Y` where W/H are the crop dimensions and X/Y are the top-left corner, all in source-resolution pixels. For 4K source (3840×2160), estimate from a 1920-wide preview by doubling.

**Good sync events to look for:**
- A tap that dismisses a modal or navigates to a new screen
- A loading spinner that finishes and a result appears
- A slide or step transition with a distinctive before/after
- A progress bar jumping to a new value
- A keyboard appearing or disappearing

**Events to avoid:**
- Continuous motion (scrolling lists, video playback) — hard to pinpoint a single frame
- Gradual transitions (fade, crossfade) — ambiguous first-visible frame
- Events that repeat frequently — could match the wrong occurrence
