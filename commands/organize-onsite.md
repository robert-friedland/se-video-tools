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

## Pipeline model — MAIN vs SUBAGENT phases

Each phase below is tagged either **MAIN** (orchestrator runs it directly) or **SUBAGENT** (orchestrator dispatches the phase body to a fresh `Agent` and only sees a structured summary). This split keeps the orchestrator's context small over a long run; user-facing checkpoints stay on the main thread, and the noisy work (ffprobe loops, `/transcribe` output, `/analyze-video` frame extraction, `/sync-visual` sweeps, GPU renders) lives inside subagents that only return ≤200-word summaries.

**SUBAGENT means dispatch via the `Agent` tool — a fresh context window.** It does NOT mean reading another Markdown file: a `Read` loads into the same conversation and defeats the purpose.

### Dispatch contract (applies to every SUBAGENT phase)

Dispatch one `Agent`. Pass it:
- The body of the SUBAGENT phase section (the instructions to execute)
- The relevant slice of `ORGANIZE_PLAN.md` (prior phases' outputs the subagent needs)
- The phase's `expected_artifacts:` list — files that MUST exist on disk for the phase to count as done

The subagent must return a structured summary in this exact shape:

```
STATUS: ok | partial | failed
ARTIFACTS_VERIFIED: yes | no — <which missing>
SUMMARY: <≤200 words: what was done, key counts, per-item issues>
ITEMS:
  - <item-id>: ok | failed: <reason> | skipped: <reason>
```

After the subagent returns, the orchestrator MUST:

1. Run a file-existence check (`test -s <path>`) against the phase's `expected_artifacts:` list. **Do not trust `STATUS` alone.**
2. If all artifacts exist AND `STATUS: ok` AND the response parses: mark the phase `[x done]` in `ORGANIZE_PLAN.md`.
3. If any artifact is missing: mark `[!] verification-failed: <which missing>` and stop the run. Surface the subagent's `SUMMARY` to the user.
4. If `STATUS: partial` or `failed`: write per-item state from `ITEMS:` into `ORGANIZE_PLAN.md` (item-level `[x]` / `[ ]` / `[!] failed: <reason>` markers) so a re-run can re-dispatch only the failed items. See "Per-item failure granularity" below.
5. If the response doesn't match the structured shape at all: mark `[!] needs-review`, surface the raw response, and stop. Never auto-promote an unparseable run to `[x done]`. Terminal status set is two: `[x done]` (verified) or `[!] <label>` (needs human eyes).

The orchestrator never extracts frames, never runs ffprobe loops, never reads a transcript, never tails a render log. It reads structured summaries and updates the state file.

### Per-item failure granularity

Phases that operate on N items (Phases 4 b-roll, 5 pair descriptions, 6 syncs, 7 composites) record per-item state in `ORGANIZE_PLAN.md` so a partial failure doesn't reset the whole phase. On resume, dispatch a subagent that handles only items still marked `[ ]` or `[!]`. The skeleton at the bottom of this file shows the shape per phase.

---

## Phase -2 — Check for resumable state

**MODE:** MAIN — orchestrator runs this directly. State-machine bootstrap; not delegated.

```bash
TARGET="<folder>"
PLAN="$TARGET/ORGANIZE_PLAN.md"
```

If `$PLAN` exists, Read it. For each phase marked `[x done]`, skip it. Resume from the first unfinished phase. Any user-confirmed decisions recorded in the file (pairings, render selections) should NOT be re-asked — reuse them.

If `$PLAN` does not exist, create it with a skeleton (see "ORGANIZE_PLAN.md structure" at the bottom of this file) and proceed to Phase -1.

**Invariant:** update `ORGANIZE_PLAN.md` after every phase completes. Side-effects (file moves, README writes, composite outputs) must land on disk *before* the corresponding phase is marked `[x done]`.

---

## Resume-from-phase escape hatch

If the user invokes `/organize-onsite resume-phase N` (or otherwise asks to "restart from Phase N with a fresh context"), the orchestrator:

1. Confirm with `AskUserQuestion`: "This will discard intermediate state for Phase N and later (no source files are deleted, but checkboxes will be reset). Continue?"
2. On confirmation, edit `ORGANIZE_PLAN.md`: change every `[x done]` and per-item `[x]` from Phase N onward to `[ ]`. Per-item `[!] failed:` markers are also reset to `[ ]`. User-confirmed decisions recorded in earlier phases (sync method, pairings, render selections) are NOT reset — they remain authoritative.
3. Resume normally from Phase N. Because subagent dispatch is fresh-context, the new run starts with the orchestrator's working set = state file + this skill, regardless of how many turns the previous attempt accumulated.

This is the user's escape hatch for "Claude got confused at Phase N." It is also the right move if a phase's on-disk artifacts have been manually edited and the recorded state is stale.

---

## Phase -1 — Ask about visual sync (only if not already recorded)

**MODE:** MAIN — orchestrator runs this directly. `AskUserQuestion` prompts can't be delegated.

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

**MODE:** SUBAGENT
**Expected artifacts on success:**
- `$TARGET/ORGANIZE_PLAN.md` — Phase 0 section filled with the inventory table

Dispatch one `Agent` with the body below as its prompt. The subagent runs the ffprobe loop and writes the table; the orchestrator only sees the structured summary. Do NOT run ffprobe in the main thread.

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

**MODE:** SUBAGENT
**Expected artifacts on success:**
- `$TARGET/ORGANIZE_PLAN.md` — Phase 1 section with classification table

Dispatch one `Agent`. The subagent applies the deterministic rules below and parallel-fans-out `/analyze-video` for the ambiguous edge cases. The user checkpoint for Phases 1 + 2 is Phase 2.5; Phase 1 itself is a clean SUBAGENT dispatch with no inline checkpoint.

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

**MODE:** SUBAGENT
**Expected artifacts on success:**
- `$TARGET/ORGANIZE_PLAN.md` — Phase 2 draft section with pairing table + TZ correction note

Dispatch one `Agent`. The subagent runs the timestamp algorithm + ambiguity-disambiguation `/analyze-video` fan-out. **The subagent does NOT move files** — pairings stay draft-only until the Phase 2.5 user checkpoint clears.

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

**MODE:** MAIN — orchestrator runs this directly. User approval gate; not delegated.

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

**MODE:** SUBAGENT
**Expected artifacts on success:**
- `$TARGET/b-roll/<original_name>.<ext>` per b-roll clip — moved (renamed in Phase 4)
- `$TARGET/perform/pair-N-<placeholder>/<dji>` and `<ipad>` per pair
- `$TARGET/perform/<...>/README.md` stub per pair / ipad-only folder

Dispatch one `Agent` to perform the file moves driven by the approved Phase 2.5 plan. Pure mechanical work; no user input.

Move (not copy) files:
- b-roll clips → `b-roll/` (still with original names; Phase 4 renames them)
- Each pair → `perform/pair-N-<placeholder>/` (slug will be filled in Phase 5; for now use `pair-N`)
- Each orphan iPad → `perform/ipad-only-N-<placeholder>/`

Write an empty stub `README.md` in each `perform/*` subfolder with file pointers.

Mark Phase 3 `[x done]`.

---

## Phase 4 — Describe & rename b-roll (parallel subagents)

**MODE:** SUBAGENT (single driver that internally parallel-dispatches `/analyze-video`)
**Expected artifacts on success (per b-roll item):**
- `b-roll/<slug>.<ext>` (renamed)

Dispatch one `Agent`. That subagent itself parallel-dispatches `/analyze-video` (one call per b-roll clip) in a single message and collects results before renaming files. Per-item granularity: the subagent reports each item's outcome in its `ITEMS:` block; the orchestrator writes per-item state into `ORGANIZE_PLAN.md`. On rerun, dispatch a Phase 4 subagent that handles only items still `[ ]` or `[!]`.

Spawn one `general-purpose` subagent per b-roll clip **in parallel** (single message, multiple `Agent` calls). Each subagent:
1. Runs `/analyze-video` on its clip (extracting ~10 frames is enough — this is low-fidelity).
2. Returns a short kebab-case slug (3–5 words, e.g. `lobby-exterior-wide`) and a 1-sentence description.

When all return, rename each b-roll file in place (`b-roll/<slug>.mp4`, preserving extension; handle collisions with `-2`, `-3` suffixes). Write the rename map to `ORGANIZE_PLAN.md` under Phase 4 and mark `[x done]`.

---

## Phase 5 — Describe each pair → README.md + folder slug (parallel subagents)

**MODE:** SUBAGENT (single driver that internally parallel-dispatches `/analyze-video`)
**Expected artifacts on success (per pair / ipad-only item):**
- `perform/<slug>/` (folder renamed) AND `perform/<slug>/README.md` filled with description

Dispatch one `Agent`. That subagent parallel-dispatches `/analyze-video` per pair / ipad-only folder in a single message. Per-item granularity applies (see Phase 4).

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

**MODE:** SUBAGENT (single driver that internally parallel-dispatches `/sync-visual`)
**Expected artifacts on success (per pair not skipped):**
- `perform/<slug>/README.md` — `Sync offset` and `Composite command` sections filled

Dispatch one `Agent`. That subagent parallel-dispatches `/sync-visual` per paired folder in a single message. Per-item granularity applies (see Phase 4). If user answered "None" to sync method in Phase -1, skip the dispatch entirely and record `Phase 6: [skipped — sync=None]` in `ORGANIZE_PLAN.md`.

Spawn one subagent per paired pair in parallel. Each subagent receives:
- The two file paths
- The **sync method** from Phase -1 (so it knows to hunt for stopwatch digits vs. button-tap transitions)
- The **search window** from Phase -1 (passed as `--stop` to the coarse sweep)

The subagent runs the `/sync-visual` skill, captures the `SYNC bg=X scr=Y` line, and writes it into the pair's `README.md` along with the recommended `composite_bezel` command line. If the subagent reports low confidence or failure, record that in `ORGANIZE_PLAN.md` with `[!] sync-failed` — the user can re-run manually.

Skip this phase entirely if the user answered "None" in Phase -1.

Mark pairs individually in `ORGANIZE_PLAN.md` as each subagent returns.

---

## Phase 6.5 — Checkpoint: review pairs & pick which to composite

**MODE:** MAIN — `AskUserQuestion` multiSelect can't be delegated. ETA computation is a one-line inline calc.

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

**MODE:** MAIN, with a one-shot subagent per render. The render → ask → adjust → re-render loop is owned by the main thread (the user is in the loop). Only the actual `composite_bezel` 15-second sample render is dispatched to a subagent so the orchestrator never accumulates raw ffmpeg output.

Per pair, per iteration:
1. Dispatch one `Agent` whose only job is to run the `composite_bezel` command at step 3 below and verify `sync_sample.mp4` exists and is non-zero. Subagent returns a single line: `OK <abs path>` or `FAIL <reason>`.
2. Main thread `open`s the sample and asks the user via `AskUserQuestion`.
3. Apply the user's nudge (iPad early/late/way-off) to `bg`/`scr`, update the pair's `README.md`, re-dispatch the render subagent.
4. Iterate until the user confirms.

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

**MODE:** SUBAGENT (single driver, serial inside)
**Expected artifacts on success:**
- For each user-selected pair: `perform/<slug>/composite.mp4` (non-zero size)
- For each user-selected ipad-only folder: `perform/<slug>/composite.mp4` (non-zero size)

Dispatch one `Agent`. That subagent loops over the user-selected items **serially** (Metal GPU contention) — it does NOT parallelize. Per-item granularity in `ORGANIZE_PLAN.md` so a partial-failure rerun resumes from the failed item only. Orchestrator never tails ffmpeg.

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
- DJI_0042.mov → lobby-exterior-wide.mp4  [x]
- DJI_0051.mov → [ ]
- DJI_0058.mov → [!] failed: analyze-video timed out
(On rerun, dispatch a Phase 4 subagent that handles only items still `[ ]` or `[!]`.)

## Pair descriptions (Phase 5)  [ ]
- pair-1 → lab-sample-entry  [x]
- pair-2 → lobby-checkin  [ ]
- ipad-only → tutorial-walkthrough  [ ]

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
