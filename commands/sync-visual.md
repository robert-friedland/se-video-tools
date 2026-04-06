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

Extract one frame every 5–10 seconds from each video to get an overview. Use fast seek (put `-ss` **before** `-i`) for speed — accuracy is not critical at this stage.

```bash
# Background — one frame every 8 seconds, first 2 minutes
for T in $(seq 0 8 120); do
  ffmpeg -ss $T -i "BG_VIDEO" -frames:v 1 -vf "scale=400:-1" -q:v 2 "$WORK/bg_$(printf '%04d' $T).jpg" -y 2>/dev/null
done

# Screen recording — same interval
for T in $(seq 0 8 120); do
  ffmpeg -ss $T -i "SCR_VIDEO" -frames:v 1 -vf "scale=400:-1" -q:v 2 "$WORK/scr_$(printf '%04d' $T).jpg" -y 2>/dev/null
done
```

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

Once you have a ±5 s window around the event in each video, extract frames at 1-second intervals with **accurate seek** (put `-i` before `-ss`) to ensure frame-accurate positioning:

```bash
# Replace BG_LO / BG_HI with your coarse window for the background
for T in $(seq BG_LO 1 BG_HI); do
  ffmpeg -i "BG_VIDEO" -ss $T -frames:v 1 -vf "crop=W:H:X:Y,scale=400:-1" -q:v 2 "$WORK/bg_med_$(printf '%04d' $T).jpg" -y 2>/dev/null
done

# Replace SCR_LO / SCR_HI with your coarse window for the screen recording
for T in $(seq SCR_LO 1 SCR_HI); do
  ffmpeg -i "SCR_VIDEO" -ss $T -frames:v 1 -vf "scale=400:-1" -q:v 2 "$WORK/scr_med_$(printf '%04d' $T).jpg" -y 2>/dev/null
done
```

Read each frame in sequence. Narrow down to the 1-second bracket where the event occurs in each video (e.g. "event happens between t=42 and t=43 in the background, between t=17 and t=18 in the screen recording").

---

## Phase 5 — Fine sweep (0.2–0.3 s intervals)

Within the 1-second bracket for each clip, extract frames at 0.2 or 0.3 second intervals. Use accurate seek (put `-i` before `-ss`):

```bash
# Replace BG_SEC with the integer second of the event in the background
for T in 0.0 0.2 0.4 0.6 0.8 1.0; do
  SEC=$(echo "BG_SEC + $T" | bc)
  ffmpeg -i "BG_VIDEO" -ss $SEC -frames:v 1 -vf "crop=W:H:X:Y,scale=400:-1" -q:v 2 "$WORK/bg_fine_${SEC}.jpg" -y 2>/dev/null
done

# Replace SCR_SEC with the integer second of the event in the screen recording
for T in 0.0 0.2 0.4 0.6 0.8 1.0; do
  SEC=$(echo "SCR_SEC + $T" | bc)
  ffmpeg -i "SCR_VIDEO" -ss $SEC -frames:v 1 -vf "scale=400:-1" -q:v 2 "$WORK/scr_fine_${SEC}.jpg" -y 2>/dev/null
done
```

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
- Fast seek (`-ss T -i VIDEO`): use for coarse sweeps. May land on a nearby keyframe; can be off by several seconds. Fast but imprecise.
- Accurate seek (`-i VIDEO -ss T`): use for medium and fine sweeps. Decodes from the previous keyframe; always lands on the exact frame. Slower but precise.

**Frame extraction template (accurate seek):**
```bash
ffmpeg -i "VIDEO" -ss T -frames:v 1 -vf "scale=400:-1" -q:v 2 "OUTPUT.jpg" -y 2>/dev/null
```

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
