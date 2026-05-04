One-shot skill that turns a folder of raw onsite footage into a Resolve-importable rough cut (`rough.xml`). Handles the full pipeline: classify clips, transcribe interviews, sync iPad↔DJI pairs, render composites, build the cut list, emit xmeml. Two modes: **(1)** AI-narrated sizzle (no interviews — narration mp3 drives audio, composites + b-roll cover visuals), and **(2)** interview-narrated sizzle (talking heads on V1, composites + b-roll on V2). Writes a resumable `SIZZLE_PLAN.md` so a failed or interrupted run can pick up where it left off.

**TRIGGER** when the user says any of:
- **"sizzle"**, **"sizzle reel"**, **"build a sizzle"**, **"customer sizzle"**, **"hero sizzle"**
- The user points this skill at a folder containing raw onsite footage and wants a finished rough cut at the end
- "Take this folder and turn it into a sizzle reel"
- The user has both onsite procedure clips and either interviews or a narration mp3 in the same folder

**SKIP** when:
- The user already has organized footage and just wants the timeline (`/interview-rough-cut` for interview-spine; `/build-timeline` directly for hand-authored cut lists)
- The user only wants composites with no rough cut (`/organize-onsite`)
- The user only wants a single composite (`/composite-bezel`) or transcript (`/transcribe`)

`/sizzle` is the comprehensive flow. `/organize-onsite` and `/interview-rough-cut` remain as direct entrypoints for users who want a subset.

## Folder layout the skill produces

```
<folder>/
  SIZZLE_PLAN.md                  # state file — keep up to date after every phase
  INVENTORY.md                    # human-readable index of every clip
  narration/                      # Mode 1 only
    narration.mp3
    narration.transcript.sentences.json
    narration.transcript.words.json
    narration.transcript.{json,txt,srt}
  interviews/                     # Mode 2 only
    <name>.mp4
    <name>.transcript.{json,sentences.json,words.json,txt,srt}
  b-roll/
    <slug>.mp4
    <slug>.meta.md                # kebab title + 1-sentence description
  perform/
    <slug>/
      <dji_original>              # moved, not copied
      <ipad_original>
      README.md                   # description + sync offsets + composite cmd
      sync_sample.mp4
      composite.mp4               # the deliverable that feeds the rough cut
  cuts.json                       # phrase- or sentence-anchored cut list
  rough.xml                       # final deliverable
```

---

## Pipeline model — MAIN vs SUBAGENT phases

Each phase below is tagged either **MAIN** (orchestrator runs it directly) or **SUBAGENT** (orchestrator dispatches the phase body to a fresh `Agent` and only sees a structured summary). This split keeps the orchestrator's context small over a long run; user-facing checkpoints stay on the main thread, and the noisy work (ffprobe loops, `/transcribe` output, `/analyze-video` frame extraction, `/sync-visual` sweeps, GPU renders) lives inside subagents that only return ≤200-word summaries.

**SUBAGENT means dispatch via the `Agent` tool — a fresh context window.** It does NOT mean reading another Markdown file: a `Read` loads into the same conversation and defeats the purpose.

### Dispatch contract (applies to every SUBAGENT phase)

Dispatch one `Agent`. Pass it:
- The body of the SUBAGENT phase section (the instructions to execute)
- The relevant slice of `SIZZLE_PLAN.md` (prior phases' outputs the subagent needs)
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
2. If all artifacts exist AND `STATUS: ok` AND the response parses: mark the phase `[x done]` in `SIZZLE_PLAN.md`.
3. If any artifact is missing: mark `[!] verification-failed: <which missing>` and stop the run. Surface the subagent's `SUMMARY` to the user.
4. If `STATUS: partial` or `failed`: write the per-item state from `ITEMS:` into `SIZZLE_PLAN.md` (item-level `[x]` / `[ ]` / `[!] failed: <reason>` markers) so a re-run can re-dispatch only the failed items. See "Per-item failure granularity" below.
5. If the response doesn't match the structured shape at all: mark `[!] needs-review`, surface the raw response, and stop. Never auto-promote an unparseable run to `[x done]`. Terminal status set is two: `[x done]` (verified) or `[!] <label>` (needs human eyes).

The orchestrator never extracts frames, never runs ffprobe loops, never reads a transcript, never tails a render log. It reads structured summaries and updates the state file.

### Per-item failure granularity

Phases that operate on N items (Phase 6 b-roll/pair descriptions, Phase 7 syncs, Phase 10 composites) record per-item state in `SIZZLE_PLAN.md` so a partial failure doesn't reset the whole phase. On resume, dispatch a subagent that handles only items still marked `[ ]` or `[!]`. The skeleton at the bottom of this file shows the shape per phase.

---

## Phase 0 — Check for resumable state

```bash
TARGET="<folder>"
PLAN="$TARGET/SIZZLE_PLAN.md"
LEGACY_PLAN="$TARGET/ORGANIZE_PLAN.md"
```

If `$PLAN` exists, Read it. For each phase marked `[x done]`, skip it. Resume from the first unfinished phase. Any user-confirmed decisions recorded in the file (mode, pairings, render selections) should NOT be re-asked — reuse them.

If `$PLAN` does not exist but `$LEGACY_PLAN` does, the user previously ran `/organize-onsite` on this folder. Read `$LEGACY_PLAN`, seed the new `$PLAN`'s Phase 2–10 sections from the matching organize-onsite phases (Inventory, Classify, Pair, Organize, Describe, Sync, Render-pick, Sync-verify, Composite — they line up 1:1), and write the new file. The user then resumes at Phase 1 (mode + scope) since organize-onsite never asked the sizzle-mode question. Tell the user: *"Found `ORGANIZE_PLAN.md`; carrying over inventory / classify / pair / sync / composite work — picking up at Phase 1 (mode)."*

If neither exists, create `$PLAN` with the skeleton at the bottom of this file and proceed to Phase 1.

**Invariant:** update `SIZZLE_PLAN.md` after every phase completes. Side-effects (file moves, README writes, composite outputs, transcripts) must land on disk *before* the corresponding phase is marked `[x done]`.

---

## Phase 0.5 — Resume-from-phase escape hatch

If the user invokes `/sizzle resume-phase N` (or otherwise asks to "restart from Phase N with a fresh context"), the orchestrator:

1. Confirm with `AskUserQuestion`: "This will discard intermediate state for Phase N and later (no source files are deleted, but checkboxes will be reset). Continue?"
2. On confirmation, edit `SIZZLE_PLAN.md`: change every `[x done]` and per-item `[x]` from Phase N onward to `[ ]`. Per-item `[!] failed:` markers are also reset to `[ ]`. User-confirmed decisions recorded in earlier phases (mode, sync method, pairings, render selections) are NOT reset — they remain authoritative.
3. Resume normally from Phase N. Because subagent dispatch is fresh-context, the new run starts with the orchestrator's working set = state file + this skill, regardless of how many turns the previous attempt accumulated.

This is the user's escape hatch for "Claude got confused at Phase N." It is also the right move if a phase's on-disk artifacts have been manually edited and the recorded state is stale.

---

## Phase 1 — Mode + scope

**MODE:** MAIN — orchestrator runs this directly. `AskUserQuestion` prompts can't be delegated to a subagent.

Ask the user, in order. Skip whichever is already in `SIZZLE_PLAN.md`.

**1.1 Mode.** Use `AskUserQuestion`:
- **Mode 1 — AI-narrated sizzle** (no interviews; narration mp3 supplies audio; visuals are composites + b-roll)
- **Mode 2 — Interview-narrated sizzle** (talking heads on V1; composites + b-roll on V2)

**1.2 Sync method** (for any iPad↔DJI pairs in the folder):
- Stopwatch on the iPad, filmed by the camera (most reliable — precise to the frame)
- Camera pointed at the screen while tapping buttons (less reliable but common)
- Other (free text)
- None (skip Phase 7 / 9 / 10 sync work; composites will not be synced)

**1.3 Sync search window.** Default if unsure: **first 3 minutes (180s)**. Tighter window = fewer frames analyzed by `/sync-visual` = faster + cheaper.

**1.4 Mode 1 only — narration mp3 path.** Ask the user for an absolute path to the narration audio. Validate the file exists and is readable. If a `<name>.transcript.sentences.json` already sits next to it (Robert may have generated it via `/elevenlabs-tts`), record that — Phase 3 will skip transcribing it. Otherwise Phase 3 transcribes it alongside the interview folder pass.

Write all answers to `SIZZLE_PLAN.md` under `## Phase 1 — Mode + scope`. Mark `[x done]`.

---

## Phase 2 — Inventory

**MODE:** SUBAGENT
**Expected artifacts on success:**
- `$TARGET/SIZZLE_PLAN.md` — Phase 2 section filled with the inventory table
- `$TARGET/INVENTORY.md` — one row per top-level clip

Dispatch one `Agent` with the body below as its prompt. The subagent runs the ffprobe loop and writes the tables; the orchestrator only sees the structured summary. Do NOT run ffprobe in the main thread.

For every video in the target folder (non-recursive, top-level only — ignore anything already inside `interviews/`, `narration/`, `b-roll/`, or `perform/`):

```bash
for f in "$TARGET"/*.{mp4,mov,MP4,MOV,m4v,mkv}; do
  [ -f "$f" ] || continue
  ffprobe -v error -print_format json \
    -show_entries format=duration,tags:stream=codec_type,codec_name,width,height:stream_side_data=rotation \
    "$f"
done
```

Collect per file:
- width, height (effective rotation)
- duration
- `creation_time` from format tags (if present)
- filesystem mtime
- has-audio
- container/codec

Write a Phase 2 inventory table to `SIZZLE_PLAN.md`. Also write the human-readable `INVENTORY.md` at the top of `$TARGET` with one row per clip: `file | class | dur | description | transcript? | composite?`. The `class`, `description`, `transcript?`, `composite?` columns fill in across later phases. Mark Phase 2 `[x done]`.

---

## Phase 3 — Classify

**MODE:** SUBAGENT → MAIN checkpoint
**Expected artifacts on success (subagent half):**
- `$TARGET/SIZZLE_PLAN.md` — Phase 3 draft section with classification table
- `$TARGET/INVENTORY.md` — `class` column populated
- For Mode 2: `<interview>.transcript.sentences.json` next to each interview clip
- For Mode 1 (if narration mp3 was provided): narration `.transcript.sentences.json`

Dispatch one `Agent` to do the automated classification work below (run `/transcribe`, classify by signals, fan out `/analyze-video` in parallel for ambiguous cases). The subagent writes its draft classifications into `SIZZLE_PLAN.md` and `INVENTORY.md` and reports a structured summary. After it returns, the **MAIN orchestrator** runs the user checkpoint at the bottom of this section (show classification table, accept corrections) and only then marks Phase 3 `[x done]`.

Run `transcribe` on the entire folder once. This is the speech-vs-not-speech classifier *and* it produces the transcripts Mode 2 needs in Phase 11. For Mode 1, also run it on the narration mp3 (unless its `.sentences.json` sidecar already exists — `transcribe` skips already-processed files by default, so a single folder pass covers both cases as long as the narration mp3 is reachable from a folder pass).

```bash
transcribe "$TARGET"
# Mode 1 only — transcribe the narration mp3 if it lives outside $TARGET:
transcribe "<narration.mp3 path>" --ext mp3,wav
```

Then apply the existing `/organize-onsite` Phase 1 rules for video classification:

**iPad screen recording** (strong signals):
- `tags.com.apple.quicktime.software` contains `iOS` / ReplayKit, or `major_brand=qt`
- Logical dimensions match an iPad mini recording (e.g. 1920×1260 / 1260×1920, or 2266×1488 / 1488×2266)
- No DJI metadata
- AND `transcribe` flagged it `not-interview` (interviews are usually iPhone/iPad selfie cam in landscape, not a screen recording)

**DJI 3rd-person**:
- 4K (3840×2160) or 2.7K with rotation metadata present, or DJI tags
- AND `not-interview` per `transcribe` (low speech ratio is the tell)

**Interview** (Mode 2 only):
- `transcribe` flagged it `likely_interview = true` (`word_count >= 30` AND ratio ≥ 0.15)
- Single-cam talking-head framing — confirm via `/analyze-video` if uncertain

**B-roll vs. performance** (within DJI clips):
- Duration < 60 s → b-roll
- 55 s – 90 s edge cases → spawn one `/analyze-video` subagent per clip in parallel; the subagent returns `b-roll` or `performance`

For ambiguous cases, fan out `/analyze-video` subagents in parallel (single message, multiple `Agent` calls) — each returns a class verdict with one-line justification.

Write classifications to `SIZZLE_PLAN.md`. Update `INVENTORY.md`'s `class` column.

**User checkpoint.** Show the classification table; wait for approval. If the user corrects anything, update both files. After approval, mark Phase 3 `[x done]`.

---

## Phase 4 — Pair iPad↔DJI

**MODE:** SUBAGENT → MAIN checkpoint
**Expected artifacts on success (subagent half):**
- `$TARGET/SIZZLE_PLAN.md` — Phase 4 draft section with the pairing table + TZ correction note

Dispatch one `Agent` to run the timestamp algorithm and the ambiguity-disambiguation `/analyze-video` fan-out described below. **The subagent does NOT move files** — pairings stay draft-only until the user checkpoint clears (this preserves the existing "no file moves before Phase 4 checkpoint" rule). After the subagent returns, the **MAIN orchestrator** runs the user checkpoint and marks Phase 4 `[x done, user-confirmed <date>]` only after approval.

(Skip in Mode 1 if there are no iPad/DJI clips. Skip if neither performance nor iPad-screen clips were classified.)

Treat timestamps as noisy:
- iPad `creation_time` ≈ recording **end** → iPad_start = creation_time − duration
- DJI `creation_time` ≈ recording **start**, but the DJI has no wifi/GPS, so its clock may be offset by a whole number of hours from the iPad

Algorithm (existing `/organize-onsite` Phase 2):
1. Compute iPad_start for every iPad clip and DJI_start for every DJI performance clip.
2. For each (DJI, iPad) candidate pair, compute `delta = iPad_start - DJI_start`.
3. If multiple candidates share a `delta` within ±15 minutes of each other, that's the TZ offset — apply to every DJI clip before matching.
4. Build a cost matrix of `|iPad_start - DJI_start|` after correction. Greedy nearest-first works for small N; Hungarian-style for ambiguous larger sets.
5. **Ambiguity trigger**: any resulting gap > 5 min, OR two iPads equally close to one DJI. Spawn parallel `/analyze-video` subagents on the candidates to disambiguate by comparing on-screen iPad content (app visible in DJI frames) against the iPad recording content.

Unpaired iPad recordings → their own `<slug>-ipad-only/` folder (no DJI to pair, but they still get a README and an `ipad_bezel` composite in Phase 10).

Write pairing decisions to `SIZZLE_PLAN.md`. **User checkpoint.** Show the pairing table; wait for approval. **No file moves before this checkpoint clears.**

After approval, mark Phase 4 `[x done, user-confirmed <date>]`.

---

## Phase 5 — Organize into folders

**MODE:** SUBAGENT
**Expected artifacts on success:**
- `$TARGET/interviews/<name>.mp4` per interview (Mode 2) — moved, not copied
- `$TARGET/narration/narration.mp3` (Mode 1) — moved from the source path supplied in Phase 1
- `$TARGET/b-roll/<original_name>.<ext>` per b-roll clip — moved (renamed in Phase 6)
- `$TARGET/perform/pair-N-<placeholder>/<dji>` and `<ipad>` per pair
- `$TARGET/perform/<slug>/README.md` stub per pair / ipad-only folder

Dispatch one `Agent` to perform the file moves driven by the approved Phase 4 plan. Pure mechanical work; no user input.

Move (not copy) files:
- Interview clips (Mode 2) → `interviews/`
- Narration mp3 (Mode 1) → `narration/` (move the `.transcript.*` sidecars too if they were generated outside `$TARGET`)
- B-roll clips → `b-roll/` (still with original names; Phase 6 renames them)
- Each pair → `perform/pair-N-<placeholder>/` (slug filled in Phase 6; for now use `pair-N`)
- Each orphan iPad → `perform/ipad-only-N-<placeholder>/`

Write empty stub `README.md` in each `perform/*` subfolder with file pointers.

Mark Phase 5 `[x done]`.

---

## Phase 6 — Describe (parallel `/analyze-video` fan-out)

**MODE:** SUBAGENT (single driver that internally parallel-dispatches `/analyze-video`)
**Expected artifacts on success:**
- For each b-roll item: `b-roll/<slug>.mp4` (renamed) AND `b-roll/<slug>.meta.md`
- For each pair / ipad-only item: `perform/<slug>/` (folder renamed) AND `perform/<slug>/README.md` filled with description
- `INVENTORY.md` updated

Dispatch one `Agent`. That subagent itself parallel-dispatches `/analyze-video` (one call per b-roll, one per pair) in a single message and collects all results before renaming files and writing meta sidecars. **Per-item granularity:** the subagent reports each item's outcome in its `ITEMS:` block; the orchestrator writes per-item state into `SIZZLE_PLAN.md` (see skeleton's Phase 6 section). On rerun, dispatch a Phase 6 subagent that handles only items still marked `[ ]` or `[!]` in the state file.

Spawn one subagent per b-roll clip and one per pair (or ipad-only folder) **in parallel** (single message, multiple `Agent` calls).

**For each b-roll clip:**
1. Run `/analyze-video` (extracting ~10 frames is enough — this is low-fidelity).
2. Return a kebab-case slug (3–5 words) and a 1-sentence description.

When all return:
- Rename each b-roll file in place: `b-roll/<slug>.mp4` (preserve extension; handle collisions with `-2`, `-3` suffixes).
- Write `b-roll/<slug>.meta.md` with frontmatter `name` + the description body. Format:
  ```markdown
  ---
  name: <slug>
  source: <original_filename>
  ---
  <one-sentence description>
  ```

**For each pair / ipad-only folder:**
1. Run `/analyze-video` on the clips (parallelize the two within the subagent if useful).
2. Return a kebab-case slug for the folder and a longer description.
3. Write `README.md` into the pair folder:
   ```markdown
   # <slug>

   ## Files
   - Background: <dji_filename> (<duration>)
   - Screen:     <ipad_filename> (<duration>)

   ## Description
   <long description: who's on camera, what app/workflow is shown, what they're doing>

   ## Sync offset
   <filled by Phase 7>

   ## Composite command
   <filled by Phase 7>
   ```

After all subagents return, rename pair folders from `pair-N-*` to `<slug>/`. Mode 2 interviews get NO description work — the transcript is already the description; their entry in `INVENTORY.md` shows the first sentence as a teaser.

Update `INVENTORY.md`. Mark Phase 6 `[x done]`.

---

## Phase 7 — Visual sync per pair (parallel `/sync-visual` fan-out)

**MODE:** SUBAGENT (single driver that internally parallel-dispatches `/sync-visual`)
**Expected artifacts on success (per pair not skipped):**
- `perform/<slug>/README.md` — `Sync offset` and `Composite command` sections filled

Dispatch one `Agent`. That subagent parallel-dispatches `/sync-visual` per paired folder in a single message. Per-item granularity applies (see Phase 6). If user answered "None" to sync method in Phase 1, skip the dispatch entirely and record `Phase 7: [skipped — sync=None]` in `SIZZLE_PLAN.md`.

(Skip if user answered "None" to sync method in Phase 1.)

Spawn one subagent per paired pair in parallel. Each subagent receives:
- The two file paths
- The **sync method** from Phase 1 (so it knows to hunt for stopwatch digits vs. button-tap transitions)
- The **search window** from Phase 1 (passed as `--stop` to the coarse sweep)

The subagent runs `/sync-visual`, captures the `SYNC bg=X scr=Y` line, and writes it into the pair's `README.md` along with the recommended `composite_bezel` command line. If the subagent reports low confidence or failure, record `[!] sync-failed` in `SIZZLE_PLAN.md` — the user can re-run manually.

Mark each pair individually in `SIZZLE_PLAN.md` as its subagent returns. When all are done, mark Phase 7 `[x done]`.

---

## Phase 8 — Pick which pairs to render

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
  ETA: ~3m

ipad-only: tutorial-walkthrough
  ScreenRec_1810.mov (4:02)
  ipad_bezel ETA: ~1m

Total if all rendered: ~11m
```

ETA formula: `duration_seconds * 0.5` for `composite_bezel` (GPU ≈ 2× realtime per the project README); `duration_seconds * 0.2` for `ipad_bezel`.

Use `AskUserQuestion` (multiSelect) to let the user pick which pairs to render. Write the selection into `SIZZLE_PLAN.md` and mark Phase 8 `[x done]`.

---

## Phase 9 — Sample sync verification (one pair at a time)

**MODE:** MAIN, with a one-shot subagent per render. The render → ask → adjust → re-render loop is owned by the main thread (the user is in the loop). Only the actual `composite_bezel` 15-second sample render is dispatched to a subagent so the orchestrator never accumulates raw ffmpeg output.

Per pair, per iteration:
1. Dispatch one `Agent` whose only job is to run the `composite_bezel` command at step 3 below and verify `sync_sample.mp4` exists and is non-zero. Subagent returns a single line: `OK <abs path>` or `FAIL <reason>`.
2. Main thread `open`s the sample and asks the user via `AskUserQuestion`.
3. Apply the user's nudge (iPad early/late/way-off) to `bg`/`scr`, update the pair's `README.md`, re-dispatch the render subagent.
4. Iterate until the user confirms.

(Skip if user answered "None" to sync method.)

Before spending GPU time on full-length renders, verify every selected pair's sync point by generating a short sample composite (~15 s around the sync event) and having the user eyeball it. **Only runs for pairs the user selected in Phase 8.** Skip ipad-only folders (no sync to verify).

For each selected pair, in order:

1. Read `bg=X scr=Y` from the pair's `README.md`.
2. Compute a 15-second window centered on the sync event:
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
4. Open it: `open "<pair_folder>/sync_sample.mp4"`. Use `AskUserQuestion`: "Does the sync look right?" → **Yes** / **No, iPad early** / **No, iPad late** / **No, way off**.
5. Handle the response:
   - **Yes** → mark the pair `[x sync-verified]` in `SIZZLE_PLAN.md`, move on.
   - **iPad early** → `scr = scr + delta` (default 0.3s). Update `README.md`, regenerate sample, re-ask.
   - **iPad late** → `scr = scr - delta` (if that goes negative, `bg = bg + delta` instead). Regenerate, re-ask.
   - **Way off** → fall back to `/sync-visual` re-run with hints. Regenerate sample, re-ask.

   Iterate until the user confirms. No iteration cap.

6. Keep `sync_sample.mp4` in the pair folder as an artifact.

After all selected pairs are verified, mark Phase 9 `[x done]`.

---

## Phase 10 — Render composites (serial, NOT parallel)

**MODE:** SUBAGENT (single driver, serial inside)
**Expected artifacts on success:**
- For each user-selected pair: `perform/<slug>/composite.mp4` (non-zero size)
- For each user-selected ipad-only folder: `perform/<slug>/composite.mp4` (non-zero size)
- `INVENTORY.md` — `composite?` column updated for rendered items

Dispatch one `Agent`. That subagent loops over the user-selected items **serially** (Metal GPU contention) — it does NOT parallelize. After each render it appends to its accumulating `ITEMS:` list. Per-item granularity in `SIZZLE_PLAN.md` so a partial-failure rerun resumes from the failed item only. Orchestrator never tails ffmpeg.

**Run serially.** `composite_bezel_gpu` is GPU-bound via Metal; concurrent runs contend for the same command queue and risk VRAM pressure on 4K HEVC.

For each selected pair, in order:
```bash
composite_bezel \
  --bg-start <bg> --scr-start <scr> \
  --audio screen \
  "<pair_folder>/<dji_file>" \
  "<pair_folder>/<ipad_file>" \
  "<pair_folder>/composite.mp4"
```

`--audio screen` because iPad mic audio is what's worth keeping (DJI picks up ambient room noise + fan hum). For ipad-only folders:
```bash
ipad_bezel "<folder>/<ipad_file>" "<folder>/composite.mp4"
```

After each render, verify `composite.mp4` exists and is non-zero, then mark that pair `[x done]` in `SIZZLE_PLAN.md`. Report progress between renders.

After everything is rendered, update `INVENTORY.md`'s `composite?` column for the rendered pairs. Mark Phase 10 `[x done]`.

At this point: `b-roll/<slug>.mp4` and `perform/<slug>/composite.mp4` are the *visual inventory* the rough cut draws from.

---

## Phase 11 — Build the cut list

**MODE:** MIXED — SUBAGENT prep + MAIN beat-picking.

**Prep subagent** (dispatch one `Agent` first):
- Mode 1: read `narration/narration.transcript.sentences.json`. For each sentence, score every b-roll + composite description in `INVENTORY.md` by lexical overlap. Emit `cuts.draft.json` with each beat's top 3 candidate sources.
- Mode 2: scan every interview's `.transcript.sentences.json` under `interviews/`. Filter sentences (≥1.5s, ≥10 words, low filler). For each candidate quote, score b-roll/composite descriptions. Emit `cuts.draft.json` with candidate quotes per interview, each scored against the visual inventory.
- The prep subagent's job is **suggestions on disk, not decisions**.

**Expected artifacts after prep:**
- `$TARGET/cuts.draft.json` (non-zero size)

**Then MAIN** orchestrator reads `cuts.draft.json` and walks beats with the user via `AskUserQuestion`. The visual-budget check, frame-rate / resolution check, and final `cuts.json` write all stay on the main thread (these are quick file probes, not noisy work). Mark Phase 11 `[x done]` only after `cuts.json` lands.

Branch on the mode chosen in Phase 1.

### Mode 1 — AI-narrated

Read `narration/narration.transcript.sentences.json`. Each sentence is a beat with known `start` and `end`. Show the user the sentence list with timestamps:

```
Beat 1 (0.00s – 4.20s): "Welcome to the lab where we cut sample turnaround time by thirty percent."
Beat 2 (4.20s – 9.80s): "Our team uses Squint to capture every step of the workflow."
…
```

For each beat, prompt the user to pick one (or more) visual sources from the inventory. Pre-suggest matches by lexical overlap between the sentence text and the descriptions in `INVENTORY.md` (composites + b-roll). Show the top 3 candidates per beat with their slugs and descriptions.

Two ways the user can specify a beat:
- **Single visual.** `{"source": "perform/<slug>/composite.mp4", "source_in": 0.0, "duration": <beat_dur>}` — the whole beat is one shot.
- **Multiple visuals.** Two or more entries whose `duration`s sum to the beat's duration. Use this for emphasis or variety. Example for a 10s beat split between two b-roll clips:
  ```json
  {"source": "b-roll/lobby-exterior.mp4", "source_in": 0.0, "duration": 5.0},
  {"source": "b-roll/team-meeting.mp4", "source_in": 0.0, "duration": 5.0}
  ```

Write `cuts.json`:

```json
{
  "name": "<folder slug> — Sizzle (AI narration)",
  "tracks": {
    "V1": [
      {"source": "<absolute path>", "source_in": 0.0, "duration": <beat_1_dur>, "label": "Beat 1"},
      {"source": "<absolute path>", "source_in": 0.0, "duration": <beat_2_dur>, "label": "Beat 2"}
    ]
  },
  "audio": {
    "A1": [
      {"timeline_start": 0.0, "duration": <total_narration_dur>, "source": "<absolute narration.mp3 path>", "source_in": 0.0}
    ]
  }
}
```

V1 entries use `source_in` + `duration` (they're flat passes through the visual sources, not phrase-anchored). The `audio.A1` block is a single entry covering the entire narration. **No `bridge_broll`, no `resolve_phrases`** — V1 is the visuals directly, and narration sentences are already time-anchored.

**Visual budget check.** For each unique visual source, sum the `duration`s × ≤ source duration − 0.34s clearance. If the user picks the same source twice with overlapping windows or runs past the source duration, error loudly and ask them to pick differently.

**Frame-rate / resolution check.** If `composite.mp4` outputs and `b-roll/*.mp4` clips don't share one frame rate or one resolution, `build_timeline` will reject the cut list. The composites all share the project's standard rate (output of `composite_bezel`, typically 30 fps from the DJI's `r_frame_rate`) but external b-roll might not. Run `ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate,width,height` on each b-roll candidate before letting the user pick it; warn (and offer to re-encode at the project rate) if anything mismatches. CLAUDE.md's frame-rate normalize rule applies: `ffmpeg -ss S -t D -r <timeline_rate> -c:v libx264 -crf 18 input.mov candidate.mp4`.

### Mode 2 — Interview-narrated

Scan every interview's `.transcript.sentences.json` under `interviews/`. Suggest candidate quotes — long enough (≥ 1.5 s, ≥ ~10 words), low filler (skip sentences that are all "um", "uh", incomplete fragments). Show one screen per interview at a time, scoring each sentence against the b-roll / composite descriptions in `INVENTORY.md` so the user sees which beats *can* be visually supported.

For each beat the user picks (in order):
- `source` = absolute path to the interview MP4
- `phrase` = byte-identical text from `.transcript.sentences.json` (single-spaced, punctuation included)
- `near` = the `start` of the first sentence the phrase touches
- `label` = optional, for review

Then prompt the user to draft the per-beat V2 plan. For each V1 beat (in order), they list 1–N b-roll/composite shots that should overlay it. Each entry is `{"source": "...", "source_in": 0.0, "label": "..."}`. Constraints (enforced when `bridge_broll` runs in Phase 12):
- Per-beat source budget (`source_dur − source_in − 0.34s clearance`) must cover the V2 span.
- Don't reuse the same `(source, source_in)` segment across beats.
- Score b-roll on what's *actually visible* (UI, screen, artifact) — not on logo/branded apparel.

Write `cuts.json` in the existing `/interview-rough-cut` shape:

```json
{
  "name": "<folder slug> — Sizzle (interviews)",
  "tracks": {
    "V1": [
      {"source": "<abs interview path>", "phrase": "...", "near": 88.83, "label": "Beat 1"},
      {"gap": 0.4},
      {"source": "<abs interview path>", "phrase": "...", "near": 128.9, "label": "Beat 2"}
    ]
  },
  "v2_plan": [
    [{"source": "perform/<slug>/composite.mp4", "source_in": 0.0, "label": "ui shot"}],
    [{"source": "b-roll/<slug>.mp4", "source_in": 0.0, "label": "context"}]
  ]
}
```

`v2_plan` length must match the V1 non-gap count exactly. Use `[]` for an intentionally bare beat (talking head only).

After `cuts.json` is written, mark Phase 11 `[x done]`.

---

## Phase 12 — Build timeline

**MODE:** SUBAGENT
**Expected artifacts on success:**
- `$TARGET/rough.xml` (non-zero size)
- `SIZZLE_PLAN.md` — `Status: done` at top, Phase 12 section filled with duration / track counts

Dispatch one `Agent` to run the mode-appropriate pipeline below and produce `rough.xml`. The orchestrator reads its summary and prints the user-facing "open in Resolve" instructions.

Branch on mode:

**Mode 1:**
```bash
build_timeline cuts.json rough.xml
```
No `resolve_phrases`, no `bridge_broll` — sentences are already time-anchored, V1 is the visuals directly.

**Mode 2:**
```bash
resolve_phrases cuts.json - | bridge_broll - | build_timeline - rough.xml
```
The existing `/interview-rough-cut` pipeline. `resolve_phrases` snaps each `phrase`/`near` cut to exact word edges; `bridge_broll` pads V1 cuts and lays out V2 b-roll to bridge V1 gaps.

Tell the user: **"Open Resolve → File → Import → Timeline… and select `rough.xml`."** Resolve auto-links sources.

Set `Status: done` at the top of `SIZZLE_PLAN.md`. Print a final summary:
- Path to `rough.xml` and its size
- Total timeline duration
- Number of V1 / V2 / A1 clips
- A reminder that the per-pair `composite.mp4` files and `b-roll/*.mp4` are the visual inventory if the user wants to swap shots in Resolve.

Mark Phase 12 `[x done]`.

---

## SIZZLE_PLAN.md skeleton

```markdown
# Sizzle — <folder>
Created: <date>
Status: in-progress | done | failed
Mode: <1 | 2 — filled in Phase 1>

## Phase 1 — Mode + scope  [ ]
Mode: 1 | 2
Sync method: stopwatch | button-taps | other: <text> | none
Search window: 180s
Mode 1 narration mp3: <abs path>  (skip if Mode 2)

## Phase 2 — Inventory  [ ]
| file | class | duration | creation_time | width | height | rotation | has_audio |

## Phase 3 — Classify  [ ]
- interview (Mode 2 only): ...
- iPad-screen: ...
- DJI-performance: ...
- DJI-b-roll: ...
- unknown: ...

## Phase 4 — Pair iPad↔DJI  [ ]
Timezone correction applied: -7h
- pair-1: DJI_0045 ↔ ScreenRec_1722  (gap 4.2s)
- pair-2: ...
- ipad-only: ScreenRec_1810

## Phase 5 — Organize  [ ]

## Phase 6 — Describe  [ ]
b-roll:
- IMG_1234.mov → lobby-exterior.mp4  [x]
- IMG_5678.mov → [ ]
- IMG_9012.mov → [!] failed: analyze-video timed out
pairs:
- pair-1 → lab-sample-entry  [x]
- pair-2 → lobby-checkin  [ ]
- ipad-only → tutorial-walkthrough  [ ]
(On rerun, dispatch a Phase 6 subagent that handles only items still `[ ]` or `[!]`.)

## Phase 7 — Visual sync  [ ]
- lab-sample-entry: bg=12.4 scr=8.1  [x]
- lobby-checkin: [ ]

## Phase 8 — Render selection  [ ]
User selected: lab-sample-entry, lobby-checkin, tutorial-walkthrough

## Phase 9 — Sync verification
- lab-sample-entry: [ ]
- lobby-checkin: [ ]

## Phase 10 — Composites
- lab-sample-entry: [ ]
- lobby-checkin: [ ]
- tutorial-walkthrough: [ ]

## Phase 11 — Cut list  [ ]
Mode: 1 | 2
Beats: <count>
File: cuts.json

## Phase 12 — Timeline  [ ]
File: rough.xml
Duration: <total>
Tracks: V1=N, V2=N, A1=N
```

Check the box and add any per-item notes as each phase completes. On resume, scan for the first `[ ]` and continue from there.

---

## Common failure modes (Phase 12)

| Symptom | Likely cause | Fix |
|---|---|---|
| Resolve: "N of M clips were not yet found" | Source TC in xmeml doesn't match embedded media TC | Re-run `build_timeline` (it ffprobes real TCs); if still failing, inspect with `ffprobe -show_entries stream_tags=timecode <path>`. |
| `frame rate mismatch` from `build_timeline` | Externally-harvested b-roll at different fps | Re-encode at timeline rate: `ffmpeg -r 30000/1001 -i in.mp4 ...` |
| `phrase not found in <file>` (Mode 2) | Quote was paraphrased, not byte-identical to sentences.json | Re-copy from `interviews/<name>.transcript.sentences.json` |
| `v2_plan has N beats but V1 has M non-gap cuts` (Mode 2) | Plan and V1 out of sync | Add/remove plan entries; use `[]` for empty beats. |
| `source budget X < beat span Y` (Mode 2) | Beat's b-roll plan can't cover its V1 span | Add another shot to that beat's plan, or pick a longer source segment / lower `source_in` |
| Black flashes between V1 cuts in Resolve (Mode 2) | Empty beat plan, or V2 didn't fill a gap | Check `bridge_broll` stderr for "non-contiguous V2 transitions" warnings; fill empty plans. |
| Mode 1: V1 ends before A1 finishes (or vice versa) | V1 `duration`s don't sum to narration duration | Recompute. The narration's `.transcript.sentences.json` last sentence's `end` is the total. V1 entries' `duration`s must sum to that. |
| Mode 1: same b-roll appears twice with overlapping `source_in` windows | User picked the same visual without offsetting | Use a different `source_in` so the visible content differs, or pick a different source. |

---

## Do NOT

- **Don't run `bridge_broll` in Mode 1.** V1 *is* the visuals; there are no V1 gaps to bridge.
- **Don't run `resolve_phrases` in Mode 1.** Narration sentences come pre-anchored; there's no phrase to look up.
- **Don't reuse the same `(source, source_in)` segment** across beats (Mode 2) — viewers notice. Use the same source with a different `source_in` so the visible content differs.
- **Don't move files before the Phase 4 user checkpoint clears.** If pairing is wrong and we've already moved files, the rollback is messy.
- **Don't run Phase 10 composites in parallel.** GPU contention causes slowdowns and VRAM pressure on 4K HEVC.
- **Don't add lead/trail past 0.20s** (Mode 2) as a reflex when whisper transcripts look truncated. Verify the audio first by re-transcribing a wider window.
- **Don't include a music track** unless the user asks. Out of scope.
- **Don't pass `2>&1` in the middle of the Mode 2 pipe** — `bridge_broll` writes a one-line summary to stderr; merging it into stdout corrupts the JSON stream. Use `2>/dev/null` or let stderr render naturally.
