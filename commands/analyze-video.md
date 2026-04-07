Analyze a video file by extracting evenly-distributed frames and describing what it contains.

## Your job when this skill is invoked

1. Ask for the video path if not already provided. Optionally ask if there is a specific question to answer (e.g. "what app is shown?", "is this clip usable for a demo?").
2. Set up a temp working directory with `mktemp -d`.
3. Run `extract_frames` to extract 15 frames in a single call.
4. Read all extracted frames.
5. Describe what the video shows. Always include timestamps for notable moments (the filenames encode them).
6. Clean up the temp directory.

---

## Phase 1 — Setup

```bash
WORK=$(mktemp -d)
echo "Working in $WORK"
```

Get the video duration so you can describe it accurately:

```bash
ffprobe -v error -show_entries format=duration -of csv=p=0 "VIDEO_PATH"
```

---

## Phase 2 — Extract frames

Extract 15 evenly-distributed frames across the full video:

```bash
extract_frames "VIDEO_PATH" 15 "$WORK"
```

This produces files named `frame_001_Xs.jpg` through `frame_015_Xs.jpg` where `X` is the timestamp in seconds.

If the user wants more or fewer frames, adjust the count (e.g. `10` for a quick overview, `20` for more detail).

---

## Phase 3 — Read and analyze

Read all the frames using the Read tool. Then describe:

- **What's in the video**: setting, people, devices, app or content on screen
- **Structure / arc**: how the content changes across the timeline (beginning vs. middle vs. end)
- **Notable moments**: anything distinctive, by timestamp (use the filenames as timestamps)
- **Answer any specific question** the user asked

Keep the description concise but concrete. If the video is clearly a product demo, say so. If it shows a specific app or workflow, name it. If screen content is legible, describe what it shows.

---

## Phase 4 — Clean up

```bash
rm -rf "$WORK"
```

---

## Key technical note

`extract_frames` uses a half-step distribution: for N frames over a window of duration W, each frame lands at `(i + 0.5) * W / N` seconds from the start. This avoids extracting the first frame (often black) while centering each sample in its equal-width slot. Timestamps in filenames are rounded to one decimal place.
