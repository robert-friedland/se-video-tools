Organize a folder of raw onsite videos: classify (iPad screen vs. 3rd-person vs. b-roll), pair iPad recordings with matching 3rd-person camera footage by timestamp + visual matching, describe each clip/pair, run visual sync, and composite. Writes a resumable `ORGANIZE_PLAN.md` into the target folder so a failed or interrupted run can pick up from where it left off.

## Your job when this skill is invoked

The user points this skill at a folder (e.g. `/organize-onsite ~/Onsites/2026-04-idexx`). The folder contains an unsorted mix of:
- iPad mini screen recordings
- DJI 3rd-person camera footage (performance clips to overlay iPad recordings on)
- DJI b-roll (typically < 60 s)

You will produce, inside that folder:
```
<folder>/
  ORGANIZE_PLAN.md          # state file — always keep this up to date
  b-roll/
    <descriptive-name>.mp4
  perform/
    <short-pair-slug>/
      <dji_original>        # moved, not copied
      <ipad_original>
      README.md             # pair description + sync offsets + composite command
      composite.mp4         # final deliverable
    <ipad-only-slug>/
      <ipad_original>
      README.md
      composite.mp4         # ipad_bezel output
```

---

## Phase -2 — Check for resumable state

```bash
TARGET="<folder>"
PLAN="$TARGET/ORGANIZE_PLAN.md"
```

If `$PLAN` exists, Read it. For each phase marked `[x done]`, skip it. Resume from the first unfinished phase. Any user-confirmed decisions recorded in the file (pairings, render selections) should NOT be re-asked — reuse them.

If `$PLAN` does not exist, create it with a skeleton (see "ORGANIZE_PLAN.md structure" at the bottom of this file) and proceed to Phase -1.

**Invariant:** update `ORGANIZE_PLAN.md` after every phase completes. Side-effects (file moves, README writes, composite outputs) must land on disk *before* the corresponding phase is marked `[x done]`.

---

## Phase -1 — Ask about visual sync (only if not already recorded)

Ask the user two questions. Skip whichever is already in `ORGANIZE_PLAN.md`.

**1. Visual sync method used during performance recordings?**
- Stopwatch on the iPad, filmed by the camera (most reliable — precise to the frame)
- Camera pointed at the screen while tapping buttons (less reliable but common)
- Other (free text)
- None (skip Phase 6; composites will not be synced)

**2. How early in the clips does the sync event occur?**
- Ask for a window (e.g. "first 30s", "first 90s", "first 3 min").
- Tell the user: *the tighter the window, the fewer frames sync-visual has to analyze — faster runs and far fewer tokens.*
- Default if unsure: **first 3 minutes (180s)**.

Write both answers to `ORGANIZE_PLAN.md` under `## Sync method`. These are passed into every Phase 6 sync subagent.

---

## Phase 0 — Inventory

For every video in the target folder (non-recursive, top level only — ignore anything already inside `b-roll/` or `perform/`):

```bash
for f in "$TARGET"/*.{mp4,mov,MP4,MOV}; do
  [ -f "$f" ] || continue
  ffprobe -v error -print_format json \
    -show_entries format=duration,tags:stream=codec_type,codec_name,width,height:stream_side_data=rotation \
    "$f"
  stat -f "%SB" "$f"   # mtime fallback
done
```

Collect per file:
- width, height (and effective rotation)
- duration
- `creation_time` from format tags (if present)
- filesystem mtime
- has-audio
- container/codec

Write a Phase 0 table to `ORGANIZE_PLAN.md`. Mark `[x done]`.

---

## Phase 1 — Classify

Deterministic rules first. Only fall back to visual inspection (spawn parallel `analyze-video` subagents) for ambiguous clips.

**iPad screen recording** (strong signals):
- `tags.com.apple.quicktime.software` contains `iOS` / ReplayKit, or `major_brand=qt`
- Logical dimensions match an iPad mini recording: commonly encoded as 1920×1260 / 1260×1920, or 2266×1488 / 1488×2266
- No DJI metadata

**DJI 3rd-person**:
- 4K (3840×2160) or 2.7K with rotation metadata present, or DJI tags

**B-roll vs. performance** (within DJI clips):
- Duration < 60 s → b-roll
- 55 s – 90 s edge cases → spawn one `analyze-video` subagent per clip in parallel; the subagent returns `b-roll` or `performance`

Write classifications to `ORGANIZE_PLAN.md`. Mark `[x done]`.

---

## Phase 2 — Pair iPad recordings with DJI performance clips

Treat timestamps as noisy:
- iPad `creation_time` ≈ recording **end** → iPad_start = creation_time − duration
- DJI `creation_time` ≈ recording **start**, but the DJI has no wifi/GPS timezone sync, so its clock may be offset by a whole number of hours (timezone drift) from the iPad

Algorithm:
1. Compute iPad_start for every iPad clip and DJI_start for every DJI performance clip.
2. For each (DJI, iPad) candidate pair, compute `delta = iPad_start - DJI_start`.
3. If multiple candidates share a `delta` within ±15 minutes of each other, that's the TZ offset — apply to every DJI clip before matching.
4. Build a cost matrix of `|iPad_start - DJI_start|` after correction. For small N, greedy nearest-first works; for ambiguous larger sets, Hungarian-style assignment.
5. **Ambiguity trigger**: any resulting gap > 5 min, OR two iPads equally close to one DJI. Spawn parallel `analyze-video` subagents on the candidates to disambiguate by comparing on-screen iPad content (app visible in DJI frames) against the iPad recording content.

Unpaired iPad recordings → their own `<slug>-ipad-only/` folder (no DJI to pair, but they still get a README and an `ipad_bezel` composite in Phase 7).

Write pairing decisions to `ORGANIZE_PLAN.md` (do not mark `[x done]` yet — wait for user confirm in Phase 2.5).

---

## Phase 2.5 — Checkpoint: confirm classification & pairing with user

Show a table:

```
b-roll:
  IMG_0042.mov  (0:48, 4K DJI)
  IMG_0051.mov  (0:33, 4K DJI)

perform (paired):
  IMG_0045.mov (14:22)  ↔  ScreenRec_17-22.mov (15:01)    gap=4.2s (after TZ=-7h)
  IMG_0048.mov (6:14)   ↔  ScreenRec_17-40.mov (6:58)     gap=1.9s

perform (ipad-only):
  ScreenRec_18-10.mov (4:02)
```

Wait for user approval. If they correct anything, update the pairing table and re-confirm. After approval, write `[x done, user-confirmed <date>]` to the Phase 2 / Phase 2.5 section.

**No file moves happen before this checkpoint.**

---

## Phase 3 — Organize into folders

Move (not copy) files:
- b-roll clips → `b-roll/` (still with original names; Phase 4 renames them)
- Each pair → `perform/pair-N-<placeholder>/` (slug will be filled in Phase 5; for now use `pair-N`)
- Each orphan iPad → `perform/ipad-only-N-<placeholder>/`

Write an empty stub `README.md` in each `perform/*` subfolder with file pointers.

Mark Phase 3 `[x done]`.

---

## Phase 4 — Describe & rename b-roll (parallel subagents)

Spawn one `general-purpose` subagent per b-roll clip **in parallel** (single message, multiple `Agent` calls). Each subagent:
1. Runs `/analyze-video` on its clip (extracting ~10 frames is enough — this is low-fidelity).
2. Returns a short kebab-case slug (3–5 words, e.g. `lobby-exterior-wide`) and a 1-sentence description.

When all return, rename each b-roll file in place (`b-roll/<slug>.mp4`, preserving extension; handle collisions with `-2`, `-3` suffixes). Write the rename map to `ORGANIZE_PLAN.md` under Phase 4 and mark `[x done]`.

---

## Phase 5 — Describe each pair → README.md + folder slug (parallel subagents)

Spawn one subagent per pair in parallel. Each subagent:
1. Runs `/analyze-video` on both clips (can internally parallelize the two if useful).
2. Returns:
   - A short kebab-case slug for the pair folder (e.g. `lab-sample-entry`)
   - A longer description: who's on camera, what app/workflow is shown, what they're doing
3. Writes `README.md` into the pair folder:
   ```markdown
   # <slug>
   
   ## Files
   - Background: <dji_filename> (<duration>)
   - Screen:     <ipad_filename> (<duration>)
   
   ## Description
   <long description>
   
   ## Sync offset
   <filled by Phase 6>
   
   ## Composite command
   <filled by Phase 6>
   ```

After all subagents return, rename pair folders from `pair-N-*` to `<slug>/`. Update `ORGANIZE_PLAN.md`, mark `[x done]`.

For ipad-only folders: same treatment (one subagent, `README.md`, slug rename) — but there's no sync section.

---

## Phase 6 — Visual sync per pair (parallel subagents)

Spawn one subagent per paired pair in parallel. Each subagent receives:
- The two file paths
- The **sync method** from Phase -1 (so it knows to hunt for stopwatch digits vs. button-tap transitions)
- The **search window** from Phase -1 (passed as `--stop` to the coarse sweep)

The subagent runs the `/sync-visual` skill, captures the `SYNC bg=X scr=Y` line, and writes it into the pair's `README.md` along with the recommended `composite_bezel` command line. If the subagent reports low confidence or failure, record that in `ORGANIZE_PLAN.md` with `[!] sync-failed` — the user can re-run manually.

Skip this phase entirely if the user answered "None" in Phase -1.

Mark pairs individually in `ORGANIZE_PLAN.md` as each subagent returns.

---

## Phase 6.5 — Checkpoint: review pairs & pick which to composite

Show the user:

```
Pair 1: lab-sample-entry
  DJI_0045.mov (14:22)  +  ScreenRec_1722.mov (15:01)
  Description: tech scanning samples and entering results into the lab UI…
  Sync: bg=12.4 scr=8.1
  Composite ETA: ~7m (14:22 × 0.5)

Pair 2: lobby-checkin
  …
  Composite ETA: ~3m

ipad-only: tutorial-walkthrough
  ScreenRec_1810.mov (4:02)
  ipad_bezel ETA: ~1m

Total if all rendered: ~11m
```

ETA formula: `duration_seconds * 0.5` (GPU throughput ≈ 2× realtime per CLAUDE.md). ipad_bezel is lighter — use `duration_seconds * 0.2` as a rough estimate.

Use `AskUserQuestion` (multiSelect) to let the user pick which pairs to render. Write the selection into `ORGANIZE_PLAN.md`.

---

## Phase 6.75 — Sample sync verification (one pair at a time)

Before spending GPU time on full-length renders, verify every selected pair's sync point by generating a short sample composite (~15 s around the sync event) and having the user eyeball it.

**Only runs for pairs the user selected in Phase 6.5.** Skip ipad-only folders (no sync to verify).

For each selected pair, in order:

1. Read `bg=X scr=Y` from the pair's `README.md`.

2. Compute a 15-second window centered on the sync event. Preserve the bg↔scr alignment by subtracting the same pre-roll from both offsets, clamped so neither goes negative:
   ```bash
   PRE=$(awk -v x="$X" -v y="$Y" 'BEGIN{m=7; if(x<m)m=x; if(y<m)m=y; print m}')
   SAMPLE_BG=$(awk -v x="$X" -v p="$PRE" 'BEGIN{print x-p}')
   SAMPLE_SCR=$(awk -v y="$Y" -v p="$PRE" 'BEGIN{print y-p}')
   ```

3. Render the sample:
   ```bash
   composite_bezel \
     --bg-start "$SAMPLE_BG" --scr-start "$SAMPLE_SCR" --duration 15 \
     --audio screen \
     "<pair_folder>/<dji_file>" \
     "<pair_folder>/<ipad_file>" \
     "<pair_folder>/sync_sample.mp4"
   ```
   Should take ~7 s on GPU.

4. Open it for the user and ask them to watch:
   ```bash
   open "<pair_folder>/sync_sample.mp4"
   ```
   Then use `AskUserQuestion`:
   - "Does the sync look right?" → **Yes** / **No, iPad overlay is early** / **No, iPad overlay is late** / **No, way off**

5. Handle the response:
   - **Yes** → mark the pair `[x sync-verified]` in `ORGANIZE_PLAN.md`, move on to the next pair.
   - **iPad early** (overlay action happens before the real-life action) → iPad is playing ahead; need to delay it relative to bg. Ask how much (default 0.3 s). New offsets: `scr = scr + delta`. Update `README.md`, regenerate sample, re-ask.
   - **iPad late** → `scr = scr - delta` (if that would go negative, shift bg up instead: `bg = bg + delta`). Regenerate, re-ask.
   - **Way off** → fall back to `/sync-visual` re-run with any hints the user provides (e.g. "the matching event is around 45 s in the background, not 12 s"). Pass the hint into the sync subagent's search window. Regenerate sample, re-ask.

   Iterate until the user confirms. No iteration cap — sync correctness matters more than time.

6. Once confirmed, keep `sync_sample.mp4` in the pair folder as an artifact (don't delete — it's useful if the user ever wants to double-check later).

After all selected pairs are verified, mark Phase 6.75 `[x done]` in `ORGANIZE_PLAN.md` and proceed to Phase 7.

---

## Phase 7 — Composite (serial, NOT parallel)

**Run serially.** `composite_bezel_gpu` is GPU-bound via Metal; concurrent runs contend for the same command queue and risk VRAM pressure on 4K HEVC. Serial is as fast or faster and gives deterministic ETAs.

For each selected pair, in order:
```bash
composite_bezel \
  --bg-start <bg> --scr-start <scr> \
  --audio screen \
  "<pair_folder>/<dji_file>" \
  "<pair_folder>/<ipad_file>" \
  "<pair_folder>/composite.mp4"
```

Rationale for `--audio screen`: iPad mic audio is usually what's worth keeping; DJI picks up ambient room noise and fan hum.

For each ipad-only folder:
```bash
ipad_bezel "<folder>/<ipad_file>" "<folder>/composite.mp4"
```

After each render, verify `composite.mp4` exists and is non-zero, then mark that pair `[x done]` in `ORGANIZE_PLAN.md`. Report progress between renders (e.g. "Pair 1/3 done in 6m18s, starting Pair 2/3").

When everything is done, set `Status: done` at the top of `ORGANIZE_PLAN.md` and print a final summary with each composite's path and size.

---

## Subagent strategy

- **Parallel where possible**: Phases 4, 5, 6 fan out subagents for all items at once (single message, multiple `Agent` tool calls). Orchestrator context stays small.
- **Serial where required**: Phase 7 composites.
- **Orchestrator never reads raw frames.** Only subagents extract/read frames; they report back structured summaries (slug, description, sync line).

---

## ORGANIZE_PLAN.md structure

```markdown
# Organize Onsite — <folder>
Created: <date>
Status: in-progress | done | failed

## Sync method
Method: stopwatch | button-taps | other: <text> | none
Search window: 180s

## Inventory (Phase 0)  [ ]
| file | class | duration | creation_time | width | height | rotation | has_audio |

## Classification (Phase 1)  [ ]
- b-roll: ...
- performance (DJI): ...
- ipad-screen: ...

## Pairing (Phase 2)  [ ]
Timezone correction applied: -7h
- pair-1: DJI_0045 ↔ ScreenRec_1722   (gap 4.2s)
- pair-2: ...
- ipad-only: ScreenRec_1810

## Checkpoint 1 (Phase 2.5)  [ ]
User confirmed: <date>

## Organize (Phase 3)  [ ]

## B-roll rename (Phase 4)  [ ]
- DJI_0042.mov → lobby-exterior-wide.mp4
- ...

## Pair descriptions (Phase 5)  [ ]
- pair-1 → lab-sample-entry
- pair-2 → lobby-checkin
- ipad-only → tutorial-walkthrough

## Sync offsets (Phase 6)
- lab-sample-entry: bg=12.4 scr=8.1  [x]
- lobby-checkin: [ ]

## Render selection (Phase 6.5)  [ ]
User selected: lab-sample-entry, lobby-checkin, tutorial-walkthrough

## Sync verification (Phase 6.75)
- lab-sample-entry: [ ]
- lobby-checkin: [ ]

## Composites (Phase 7)
- lab-sample-entry: [ ]
- lobby-checkin: [ ]
- tutorial-walkthrough: [ ]
```

Check the box and add any per-item notes as each phase completes. On resume, scan for the first `[ ]` and continue from there.
