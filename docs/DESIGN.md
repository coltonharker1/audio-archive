# audio-archive — Design Document

> **Historical record of the old Go app,** which was replaced by Remanence and removed
> from this repo in November 2026. The paths below no longer exist; the code is in git
> history up to commit `9c9d587`. For current work, see
> [native-app-plan.md](native-app-plan.md).

> This document explains **what the project is, why it exists, how it thinks
> about hard problems, and what's currently solid vs. known-flaky**. For how
> to install and run it, see [README.md](../README.md). For the north-star
> integration with remanence-archive, see [remanence-integration.md](remanence-integration.md).

## Table of contents

1. [Current state / session handoff](#current-state--session-handoff)
2. [What and why](#what-and-why)
3. [Goals and non-goals](#goals-and-non-goals)
4. [Architecture overview](#architecture-overview)
5. [Pipeline stages](#pipeline-stages)
6. [Design decisions](#design-decisions)
7. [Hard problems and how we handle them](#hard-problems-and-how-we-handle-them)
8. [What's solid vs what's flaky](#whats-solid-vs-whats-flaky)
9. [Optimization roadmap](#optimization-roadmap)
10. [Future work](#future-work)

---

## Current state / session handoff

> This section is the **first thing to read when picking this project up
> in a fresh session.** It captures where things stand as of the most recent
> work so you don't have to reconstruct context from git log alone.

**Last updated:** 2026-04-16 (end of session).

### Session of 2026-04-16 (web review app + per-recording model + prep chain + DB cleanup)

**Major theme:** Shifted the review workflow from outbox folders to a
proper web app, added per-recording transcribe model overrides with a
historical-data–driven time estimator, swept the DB of pre-sync debris,
and tested prep-chain improvements (net neutral). Everything is still
uncommitted across both repos — same as the end of the prior session.

#### 1. Next.js web app at `web/` (shipped)

A full review UI lives at `audio-archive/web/`. Monorepo — the app reads
the same SQLite DB directly and POSTs to its own API to drive the Go
pipeline. Runs at `localhost:3001` (port 3000 has a Tailwind conflict
with another project on this machine).

Stack: Next.js 16 (App Router, Turbopack), TypeScript, Tailwind v4,
`better-sqlite3`. No auth — local-only by design.

Pages:
- `/` — recordings table. Shows title, speaker, duration, date, status
  (Local → Approved → Synced).
- `/recordings/[id]` — detail page with:
  - Audio player + **click-to-seek transcript** with per-segment highlight
    as audio plays. Segments come from `transcripts.segments` (JSON).
  - **Edit mode** for the transcript — textarea with Save/Cancel. Edits
    update `transcripts.full_text` and preserve segments. (Segment
    timestamps become approximate after edits; a re-transcribe regenerates
    them from scratch.)
  - **Actions panel** — Re-prep / Re-transcribe / Re-summarize / Re-process
    all buttons. Model selector dropdown (base/small/medium/large-v3) for
    transcribe. Live time estimate next to the dropdown.
  - **Context editor** — textarea for `recordings.context` with "Save"
    and "Save & re-summarize" buttons. Same field the Go watcher
    populates from `context.txt` files.
  - **Approval toggle** at the top-right of the title. Sets
    `recordings.approved_at`. Surfaces as a blue "Approved" badge on the
    home table.
  - Jobs list shows model badges when present (e.g. "medium" pill).
  - Group members list when applicable.
- `/search?q=…` — covers transcripts (FTS5 snippets), recording titles,
  speakers, and summary metadata (tags/topics/people/places). Results
  show a source badge indicating which field matched.

Layout:
- Header has **live status bar** polling `/api/status` every 3s. Green
  "idle" when nothing running, animated yellow "N running, M pending"
  when active. Complete/failed counts visible at all times.
- Nav: Recordings | Search.

API surface:
- `GET  /api/recordings` / `GET /api/recordings/[id]`
- `GET  /api/recordings/[id]/audio` — streams the prep WAV
- `PATCH /api/recordings/[id]` — body `{context?, approved?}`
- `POST  /api/recordings/[id]/jobs` — body `{stages, model?}`. Returns
  enqueued job IDs + total time estimate.
- `GET  /api/recordings/[id]/estimate?stages=…&model=…` — duration
  breakdown per stage + total. Reads the last 20 completed transcribe
  jobs for the given model to derive realtime factor; falls back to
  built-in defaults (base 30x, small 20x, medium 14x, large-v3 4x).
- `PUT  /api/transcripts/[id]` — body `{fullText, segments}`. Used by
  transcript edit mode.
- `GET  /api/status` — pending/running/complete/failed counts.

SQLite connection: one shared writable connection (`getDb` / `getWriteDb`
both return it). An earlier readonly connection hit `SQLITE_CORRUPT_VTAB`
snippet failures under concurrent WAL writes from the worker — the
shared writable connection fixed it. The app only runs locally and
there's only one reviewer, so there's no real concurrency concern to
protect against.

#### 2. Per-recording model override (shipped)

- New column `jobs.model` (NULL = use config default; "base" | "small" |
  "medium" | "large-v3" | etc. overrides on a per-job basis).
- `store.EnqueueJobWithModel(recID, type, model)` alongside the existing
  `EnqueueJob`.
- Worker handler reads `job.Model` and swaps `cfg.WhisperCppModel` to
  `~/.audio-archive/models/ggml-{model}.en.bin` before calling
  `pipeline.TranscribeRecording`. No signature changes to the pipeline.
- `ggml-medium.en.bin` (1.4 GB) downloaded to `~/.audio-archive/models/`.
  Not bundled, not checked in.

**Finding on model tradeoff:** Benchmarked base vs medium on the
E. Stanley Jones sermon (id 5) and the phone call (id 2):

- **Sermon (clear single speaker on tape):** medium is a dramatic
  upgrade. "The film sat alongside" → "The friend sat alongside",
  "Then the train said" → "Then this friend said", "a fine, 50 girl"
  → "a fine Christian girl". Entire passages become coherent.
- **Phone call (compressed, multi-speaker):** medium *regresses*.
  Lost proper names ("Carl" → "Call", "James" → "Shame"). Phone audio's
  bandwidth limits (~300–3400 Hz) strip information that larger models
  can't recover; their guesses happen to be worse than base's pattern
  matches.

**Decision:** base stays the default. Medium is surfaced as a
per-recording override through the UI. The model dropdown on the detail
page makes this a zero-friction choice per recording.

#### 3. FFmpeg prep chain expanded (shipped, measurable impact = 0)

Added four new filters to `internal/audio/prep.go` targeting common tape
noise profiles:

```
aformat 16kHz mono
  → bandreject f=60/120/180/240 Hz (de-hum, notch Q=5 each)
  → highpass f=80
  → afftdn nf=-25         (FFT denoiser for tape hiss)
  → acompressor           (even out dynamic swings)
  → loudnorm I=-16
```

Old prep ran in 44s on the 35-min sermon; new prep in 53s (~20%
slower, negligible for a one-time op).

**Finding:** transcripts produced with base+old-prep and base+new-prep
are **byte-identical** on both the sermon and the phone call. The
source audio in this batch is already clean enough that the new filters
don't change what Whisper hears. Keeping the chain — the cost is trivial
and it's genuinely useful insurance for noisier tapes we haven't
processed yet. But don't expect a quality lift on already-clean
digitizations.

#### 4. DB migrations + `archive reprocess` CLI (shipped)

- `ALTER TABLE jobs ADD COLUMN model TEXT` and
  `ALTER TABLE recordings ADD COLUMN approved_at TEXT` added to
  `internal/store/migrations.go`.
- `archive reprocess [ids…]` and `archive reprocess --all` enqueue fresh
  prep/transcribe/summarize jobs for a set of recordings. `internal/cli/reprocess.go`.
- FTS5 UPDATE/DELETE triggers added to the migration (`transcripts_au`,
  `transcripts_ad`) alongside the existing AFTER INSERT trigger.
  Cause: the old insert-only trigger left stale docsize entries when
  transcripts were replaced by re-processing, causing
  `SQLITE_CORRUPT_VTAB` on `snippet()` calls from the web app's search.
  The in-place fix was `INSERT INTO transcripts_fts(transcripts_fts)
  VALUES('rebuild')` — now guarded going forward by the new triggers.

#### 5. Pre-sync DB cleanup (done, still uncommitted)

- **Deleted recording 8** — same MD5 as recording 6 (`63db8f13…`). A
  duplicate ingest a day apart that the dedup logic missed because the
  slug + date prefix differed. Removed: DB rows (recordings, jobs,
  transcripts, summaries), master file, prep file.
- **Added recordings 6 and 7 to the accordion group** —
  `group_id=ec0c9af6831c3853`. They were ingested before the group was
  set up. Now sync as part of the cohesive RA sound.
- **Normalized accordion titles:** rec 11 got a YMA prefix; rec 13's
  en-dash converted to em-dash; the four Christmas show parts now
  number 1/2/3/4 sequentially instead of having duplicate titles.
- **Group title** changed from the folder name `"accordion"` to
  `"YMA Accordion Recordings"` — this becomes the RA sound's display
  name on sync.
- **Deleted 9 stale failed job rows** — historical artifacts of the
  Apr 15 OOM cascade. All those recordings had since been retried and
  completed successfully; the rows were purely cosmetic clutter. Queue
  is now 158 complete, 0 failed.

Final state of the accordion group: **9 tracks** (was 7 in-group + 2
orphans), consistent titles, meaningful group name, all ready for
`archive sync --pending`.

### What is working end-to-end

Same drop-and-forget flow as before, plus the web review surface:

1. Drop a file (or folder) in `~/audio-inbox/`. Optional `context.txt`
   primes the summarization prompt.
2. Watcher ingests, enqueues prep/transcribe/summarize.
3. Worker processes them. After summarize: source file moves to
   `~/audio-inbox/processed/`, outbox folder written to
   `~/.audio-archive/outbox/`.
4. **Review in the web app at `localhost:3001`** — listen to audio,
   click-to-seek through transcript, edit transcription mistakes, edit
   context + re-summarize, pick a stronger model for a specific tough
   recording, mark approved.
5. `archive sync <id>` / `archive sync --pending` pushes approved items
   to remanence-archive.

### First thing to do next session

```bash
# 1. Commit everything. Both repos still dirty.
cd ~/code/me/audio-archive && git status
cd ~/code/me/remanence-archive && git status

# 2. Start the web app if you want the review surface.
cd ~/code/me/audio-archive/web && npm run dev
# → http://localhost:3001

# 3. Sync the accordion group when ready.
cd ~/code/me/audio-archive && ./archive sync --pending
```

### Key tripwires from this session

- **Web app uses port 3001, not 3000** — port 3000 has a Tailwind
  resolution conflict with another project's pnpm-hoisted `vite`. If
  you ever run the app on another port and see a module-resolution
  error pointing at `~/code/worlds/worlds-ui/...`, that's the cause.
- **FTS5 `snippet()` needs UPDATE/DELETE triggers.** Without them,
  reprocessing silently corrupts the docsize index and every
  snippet-producing query raises `SQLITE_CORRUPT_VTAB`. The migration
  now installs all three triggers (AI/AU/AD). If this ever happens
  again: `sqlite3 archive.db "INSERT INTO transcripts_fts(transcripts_fts)
  VALUES('rebuild');"`.
- **Medium model regresses on phone audio.** Not a bug — the model
  can't invent bandwidth that isn't in the source. Pick base (the
  default) for phone calls; use the UI's model dropdown to pick medium
  for sermons.
- **The new prep chain's impact is audio-dependent.** Don't expect it
  to change Whisper output on already-clean digitizations. It's
  insurance for noisy material.
- **One shared DB connection from the web app.** Not readonly — it's
  easier and safer than fighting WAL snapshot semantics. The pragmas
  are set once at first open and it handles all reads and writes.
- **Per-recording model override flows through `jobs.model`.** The
  transcribe handler swaps `cfg.WhisperCppModel` before calling the
  pipeline. If you add more job types that care about model, read
  `job.Model` the same way.
- **Deleting recordings is not a CLI command yet.** The pre-sync
  cleanup went straight through SQL + `rm` on the master/prep files.
  If this becomes common, add `archive rm <id>` that cascades properly
  (jobs, transcripts, summaries, fts, master file, prep file).

### Quick reference to where the new stuff lives

| What | Where |
|---|---|
| Next.js app | `web/` |
| Web SQLite access | `web/src/lib/db.ts` |
| Web queries (read) | `web/src/lib/queries.ts` |
| Web mutations (write) | `web/src/lib/mutations.ts` |
| Duration estimator | `web/src/lib/estimate.ts` |
| Recording detail page | `web/src/app/recordings/[id]/page.tsx` |
| Playback + transcript | `web/src/app/recordings/[id]/components/RecordingPlayback.tsx` |
| Context editor | `web/src/app/recordings/[id]/components/ContextEditor.tsx` |
| Action panel | `web/src/app/recordings/[id]/components/ActionPanel.tsx` |
| Approval toggle | `web/src/app/recordings/[id]/components/ApprovalToggle.tsx` |
| Live status bar | `web/src/components/StatusBar.tsx` |
| Search page | `web/src/app/search/page.tsx` |
| Model override in worker | `internal/jobs/handlers.go` (`job.Model` swap) |
| Reprocess command | `internal/cli/reprocess.go` |

---

### Session of 2026-04-12 → 2026-04-15 (remanence integration + outbox + optimization)

**Major theme:** Built the upstream remanence-archive integration end-to-end,
then iterated on workflow ergonomics based on real-world friction. Final
state replaces auto-sync with a review-first outbox model and adds three
concurrency/safety fixes that came directly out of failure modes we hit.

**Nothing is committed yet** — both repos have unstaged changes covering
all of the work below. First action next session is to commit and push.

#### 1. Remanence-archive sync API (shipped)

In `remanence-archive`:

- Added `metadata` JSONB column to `sounds` table. Migration:
  `drizzle/0001_add_metadata_column.sql`. Already run against Neon prod.
- New API key auth helper: `src/lib/sync-auth.ts`. Reads `SYNC_API_KEY`
  env var, validates `Authorization: Bearer <key>`. Returns 501 if not
  configured, 401 on mismatch.
- `GET /api/sync` reserves and returns the next catalog number (RA-XXX).
- `POST /api/sync/upload` returns presigned R2 URLs for a batch of files
  (audio + transcript) in one round trip.
- `POST /api/sync` creates or updates a sound record. Lookup is by
  `metadata.audio_archive_id` so re-syncs update rather than duplicate.
  R2 keys in `tracks[].audioUrl/downloadUrl` get auto-resolved to public
  URLs via `getPublicUrl()`. Transcript key in `metadata.transcript_key`
  is resolved to `metadata.transcript_url`.
- New records always created with `published: false` so admin reviews
  before they appear on the public catalog.
- `PATCH /api/sounds/[id]` accepts `metadata` so admins can edit it.

In `audio-archive`:

- New `internal/sync/client.go` — HTTP client. `SyncRecording` for single
  recordings, `SyncGroup` for grouped multi-track sounds.
- New `internal/cli/sync.go` — `archive sync <id>` and `archive sync --pending`.
  Auto-detects group membership; if a recording is in a group, syncs the
  whole group as one multi-track RA sound.
- `internal/store/sync.go` — `MarkSynced`, `SyncableRecordings`, `GetRemanenceCatalogNumber`.
- New columns on `recordings`: `synced_at`, `remanence_catalog_number`.

Auth: `REMANENCE_URL` and `REMANENCE_SYNC_KEY` env vars (or `--url`/`--key` flags).
Sync key is in `remanence-archive/.env.local`.

#### 2. Grouping (folder-based + post-hoc)

Recordings from the same physical tape can now be synced as one RA sound
with multiple tracks:

- New columns on `recordings`: `group_id`, `group_title`. Index on `group_id`.
- `internal/store/groups.go` — `NewGroupID`, `SetGroup`, `GetGroupRecordings`,
  `GetRecordingGroup`, `IsGroupFullySummarized`, `SyncableGroups`.
- **Watcher folder detection**: a directory in the inbox is treated as a
  group. All audio files inside get the same `group_id`, folder name
  becomes the group title. Each file still goes through prep/transcribe/
  summarize individually.
- **CLI**: `archive group 2 4 5 --title "Accordion Performances"` for
  post-hoc grouping when files were ingested individually.
- **Sync flow**: `archive sync <id>` on a grouped recording syncs the
  whole group. `--pending` syncs groups as units, ungrouped recordings
  individually. Group sync merges tags, topics, quotes from all members
  and creates one RA sound with N tracks.

#### 3. Inbox lifecycle: source files move to processed/

After successful summarize, the original inbox file moves to
`~/audio-inbox/processed/`. Prevents accidental re-ingest if you clear
and rebuild the archive.

- New column on `recordings`: `source_path` (original inbox path).
- Watcher's `processFile` and `processFolder` call `SetSourcePath` after
  ingest.
- Post-summarize hook in `internal/jobs/handlers.go` calls
  `moveSourceToProcessed` — best-effort, doesn't fail the job.
- **Tripwire**: the watcher's `isHiddenOrTemp` filter now treats `processed`
  as a reserved folder name so it isn't picked up as a group folder.
  See `processed/` check in `isHiddenOrTemp`.

#### 4. Outbox folder (replaces auto-sync)

After summarize completes, the worker writes a review folder under
`~/.audio-archive/outbox/`:

```
outbox/
  2026-04-15_<slug>/
    transcript.txt
    summary.txt          ← human-readable
    summary.json         ← machine-readable RecordingSummary
    <name>.prep.wav      ← symlink to prep file for listening

  2026-04-15_<group-title>/    (for grouped recordings)
    overview.txt               ← combined summary across tracks
    track-1-transcript.txt
    track-1-summary.{txt,json}
    track-1-<name>.prep.wav
    ...
```

For groups, the outbox is only written when `IsGroupFullySummarized`
returns true — so all members are in the folder before review.

**This replaced an earlier auto-sync to RA implementation.** Auto-sync was
working (env vars in worker plist), but in practice you want to review
summaries, add provenance, attach pamphlet scans, etc. before pushing to
RA. The outbox gives a non-web review surface. `archive sync` is still
the manual command to push to RA.

`OutboxDir()` added to `config.Config`, included in `EnsureDirs`.

#### 5. Context support — feed Claude a backstory

Claude summaries can now be primed with user-provided context (e.g. the
provenance of a tape collection). Drop a `context.txt` and the watcher
will load it; the summarizer prepends it to the prompt under a
"User-Provided Context" section.

- `context.txt` in a folder applies to all recordings in that group.
- `<filename>.context.txt` alongside an individual file applies just to
  that one. `context.txt` in the same dir is the fallback.
- New column on `recordings`: `context`.
- `SummarizeInput.Context` field flows through to Claude prompt.
- See `accordion-context.txt` on the desktop for the YMA example.

#### 6. Three optimizations from the Apr 15 batch incident

A 7-recording accordion batch failed catastrophically (3 transcribes
OOM-killed, cascade-failed downstream summarizes). Three fixes shipped
in response:

1. **Don't enqueue jobs on skip** — `processFolder` was enqueuing
   prep/transcribe/summarize even when `IngestFile` returned `Skipped: true`
   (because the file was already in the archive). On watcher restart,
   this doubled the queue. Fix: `continue` after skip log in `processFolder`.
   `processFile` was already correct via `if !w.opts.EnqueueJobs` check
   ordering.

2. **Worker PID lock** — two `archive worker` processes running
   simultaneously deadlock the SQLite single-writer connection. The Apr 15
   incident lost ~30 minutes to a stale shell-launched worker contending
   with the daemon. Fix: `acquireWorkerLock` in `internal/cli/worker.go`
   writes `~/.audio-archive/worker.pid`, refuses to start if another
   worker is alive (signal-0 liveness check). Stale PID files are
   silently removed.

3. **Transcribe concurrency cap = 1** — whisper.cpp pins the GPU and
   uses substantial memory; running 3 in parallel triggered OOM kills on
   the bigger accordion files. Fix in `ClaimNextPendingJob` SQL: a
   transcribe job is only claimable if no other transcribe is currently
   `running`. Prep (FFmpeg, CPU) and summarize (Claude HTTP) still run
   freely concurrent. Worker pool size unchanged at 3.

Build is clean. **Daemons must be reinstalled to load the new binary
before next batch.**

### What is working end-to-end

Same drop-and-forget flow as before, plus:

1. Drop a file (or folder for groups) in `~/audio-inbox/`.
2. Optionally include `context.txt` for richer summarization.
3. Watcher ingests, enqueues prep/transcribe/summarize.
4. Worker processes them. After summarize:
   - Source file moves to `~/audio-inbox/processed/`.
   - Outbox folder written to `~/.audio-archive/outbox/<date>_<slug>/`.
5. **Review the outbox folder.** Read summaries, listen to prep files.
6. Run `archive sync <id>` (or `--pending`) to push to RA as draft.
7. Edit/publish in RA admin at `localhost:3333/admin`.

### Where the accordion batch stands

When this session ended, 3 whisper-cli processes were still actively
transcribing the larger accordion files from the troubled batch. The DB
showed 9 jobs failed (3 transcribe OOMs + 6 cascaded summarizes), 43
complete, 23 pending. The failed recordings (12, 13, 14 — three of the
xmas show segments) need transcribe retries. After the failed batch,
some recordings (9, 10, 11, 15) likely did get summarized successfully
with the YMA context applied — check the outbox to see which.

### First thing to do next session

```bash
# 1. Make sure no stale workers, check current state
ps aux | grep "archive worker"
cd ~/code/me/audio-archive
./archive status

# 2. Reinstall daemons to load the optimized binary
make reinstall-daemons

# 3. Inspect what made it through from the accordion batch
ls -la ~/.audio-archive/outbox/
cat ~/.audio-archive/outbox/*accordion*/summary.txt 2>/dev/null

# 4. Decide: retry the failed transcribes, or wipe and re-ingest
# To retry just the failures:
sqlite3 ~/.audio-archive/archive.db "
  UPDATE jobs SET status='pending', attempt=0, error=NULL, finished_at=NULL
  WHERE recording_id IN (12,13,14) AND status='failed';
"

# To start completely clean, see the previous-session notes for the
# clear-and-reingest sequence (rm -f archive.db, rm -rf masters/processed/
# transcripts/metadata/, then drop folder back into ~/audio-inbox/).

# 5. Commit everything
cd ~/code/me/audio-archive && git status
cd ~/code/me/remanence-archive && git status
```

### Known remaining work / tech debt

- **No commits yet** for any work in this session. Both repos dirty.
- **RA detail page (`/archive/[slug]`) doesn't display sync metadata.**
  Topics, tags, speakers, bible references, quotes are sitting in
  `metadata` JSONB but invisible to visitors. Transcript URL is in
  metadata but no UI for it.
- **No catalog search.** `/catalog` is a flat list with no filter.
- **RA not deployed.** Auto-sync env vars in plist template were removed
  when we replaced auto-sync with outbox; that's correct since sync is
  now manual. If RA gets deployed and auto-sync is desired again later,
  the env vars can be restored.
- **Skip-transcribe-for-music optimization not done.** Suggested in
  optimization roundup but not built. Would speed up music-heavy
  recordings significantly (whisper currently transcribes every minute
  even for accordion music with no speech).

### Email drafts on the desktop

For Mike Aman / YMA outreach (the accordion school whose recordings are
in this collection):

- `~/Desktop/mike-aman-email.txt` — direct email to Monarch Accordions.
- `~/Desktop/montgomery-steward-email.txt` — to Marvin Steward's funeral
  home (he was a YMA student/Junior Band director and these tapes came
  from his estate; his obituary led us to identify him).
- `~/Desktop/monarch-facebook-post.txt` — for the Friends of Monarch
  Accordions Facebook group.
- `~/Desktop/yma-description.txt` — full RA description with corrected
  Pueblo, CO location and the Marvin Steward provenance.
- `~/Desktop/accordion-context.txt` — the context.txt content used for
  the accordion batch.

### Key tripwires from this session (in addition to prior tripwires)

- **`worker.pid` file at `~/.audio-archive/worker.pid`** — if a worker
  exits ungracefully (kill -9, machine crash) the file is stale. Liveness
  check is signal-0. If you ever see "another worker is already running"
  and `ps` shows nothing, just delete the file.
- **`processed/` folder name is reserved in the inbox.** The watcher
  ignores it as a group folder candidate. Don't name a real audio folder
  "processed".
- **R2 key vs URL gotcha in sync** — AA sends R2 keys (e.g.
  `audio/ra-007-1234.wav`), RA's sync route resolves them to full public
  URLs via `getPublicUrl`. If you change the R2 bucket or public URL
  config in RA, both AA and RA payloads stay valid because resolution
  happens server-side.
- **Re-syncing overwrites RA edits.** Updates are keyed by
  `metadata.audio_archive_id`. If you edit a sound in RA admin and then
  re-sync from AA, the AA payload wins. Default behavior of `--pending`
  skips already-synced recordings, so this only happens if you
  explicitly `archive sync <id>` again.
- **Outbox uses symlinks for prep WAVs**, not copies. If you delete the
  prep file from `~/.audio-archive/processed/`, the outbox symlink
  breaks. Don't archive or move the outbox without `cp -L` or similar.
- **Folder ingest groups files non-recursively.** Only the immediate
  contents of a top-level inbox folder are grouped. Subfolders are not
  descended.

---

### Session of 2026-04-11 / 2026-04-12 (marathon session)

**11 commits pushed to `origin/main`.** The pipeline was fundamentally
transformed in a single session. Summary of what shipped:

1. **Transcribe hang fix** — subprocess safety (`Setpgid`/`Cancel`/`WaitDelay`) for the Python faster-whisper path. Solved the pipe-deadlock that killed the overnight batch.

2. **whisper.cpp cutover** — replaced faster-whisper with native `whisper-cli` + Metal GPU. **33× transcribe speedup** (r005 sermon: 56m→1m41s). Python worker deleted, zero Python in the tree.

3. **launchd QoS fix** — `ProcessType=Background` was throttling whisper-cli to E-cores (~200× slower). Removed from worker plist. Watch daemon keeps Background (appropriate for fsnotify I/O).

4. **Dispatcher bug fixes** — (a) graceful-shutdown `context.Canceled` no longer burns retry attempts; (b) predecessor dependency filter prevents summarize from being claimed before transcribe completes; (c) cascade-fail marks downstream jobs terminal when predecessor fails.

5. **Worker concurrency = 3** — prep, transcribe, and summarize can now run in parallel across different recordings.

6. **Claude Code CLI as summarization engine** — replaced Ollama/Mistral 7B with `claude -p` via subprocess. Single-prompt, no chunking. Dramatic quality improvement: entity extraction went from 0–2 people to 7–27 per sermon; the misclassified `broadcast` is now correctly `lecture` with speaker name and venue identified; bible references are structured with book/chapter/verse; dates are estimated from content not copied from file metadata.

7. **Recording metadata backfill** — post-summarize hook writes title, speaker, and estimated_date back to the recordings row so `archive list` shows meaningful columns.

**End-to-end benchmark (clean batch, all fixes active):**
9 recordings, ~7 hours of audio, processed from zero in ~20 minutes.
Zero failures. Compare to the original overnight batch: ~10 hours,
4/9 completed, 1 hung indefinitely.

### What is working end-to-end

The full "drop a file, get a searchable archive entry" flow is live:

1. Drop any supported audio file in `~/audio-inbox/`.
2. The **`watch` launchd daemon** detects it via fsnotify, waits for size stability, and ingests.
3. Prep / transcribe / summarize jobs are enqueued with predecessor dependency ordering.
4. The **`worker` launchd daemon** (3 goroutines) processes jobs: prep via FFmpeg, transcribe via whisper.cpp + Metal, summarize via Claude Code CLI.
5. After summarize, recording metadata (title, speaker, date) is backfilled from the summary.
6. `archive list`, `archive show <id>`, `archive search <phrase>` let you browse.

### First thing to do next session

```bash
./archive status   # should be 0 pending, 0 failed
./archive list     # see the enriched metadata
```

Then start the **remanence integration** — the north star. All prerequisites are met:
- Summarization quality is publication-ready (Claude)
- Pipeline handles real tapes robustly (27/27 in latest batch)
- `archive list` shows meaningful metadata

Work is in two repos:
1. **remanence-archive**: `ALTER TABLE sounds ADD COLUMN metadata JSONB DEFAULT '{}'`, new `POST /api/sync` endpoint with API-key auth
2. **audio-archive**: `archive sync <id>` command, `synced_at` + `remanence_catalog_number` tracking columns, upload to R2 via presigned URL

Design is sketched in [remanence-integration.md](remanence-integration.md).

### Key tripwires to remember

- **`ProcessType=Background` MUST NOT be set on the worker launchd plist.** See commit `1f8fac4` and the loud comment in the plist template. Caused ~200× slowdown on whisper.cpp when it was set.
- **`applySubprocessSafety` in `internal/transcribe/subprocess.go` is load-bearing.** The `Setpgid` + custom `Cancel` + `WaitDelay` trio prevents pipe-deadlock hangs. `TestTranscribeSubprocessSafety_GrandchildDoesNotHang` is the regression guard.
- **whisper.cpp is the only transcribe backend now.** No Python anywhere. If reintroducing Python for any reason, you'll need the multiprocessing pipe-deadlock protections again.
- **Claude CLI path must be absolute in config** (`~/.local/bin/claude`). launchd's PATH doesn't include `~/.local/bin`. Same class of bug as the original whisper-cli PATH issue.
- **Run-to-run LLM variance is much lower with Claude** but not zero. The same recording re-summarized may produce slightly different entity counts or phrasings.
- **`SetMaxOpenConns(1)` on the SQLite connection is still load-bearing** — eliminates SQLITE_BUSY errors from concurrent writes.
- **The predecessor dependency filter in `ClaimNextPendingJob`** uses a NOT EXISTS subquery. If you add a new job type, add its predecessor mapping to `predecessorType` in `internal/store/jobs.go` or it won't be dependency-gated.

### Quick reference to where things live

| What | Where |
|---|---|
| CLI entry point | `cmd/archive/main.go` |
| Pipeline logic (pure functions) | `internal/pipeline/` |
| Job manager + handlers | `internal/jobs/` |
| SQLite store + migrations | `internal/store/` |
| Summarization — Claude engine | `internal/summarize/claude.go` |
| Summarization — Ollama engine (offline fallback) | `internal/summarize/engine.go` |
| Summarization types + model profiles | `internal/summarize/types.go` |
| whisper.cpp wrapper (active transcribe backend) | `internal/transcribe/whispercpp.go` |
| Shared transcribe types (`Result`, `Segment`) | `internal/transcribe/types.go` |
| Subprocess safety (process group + WaitDelay) | `internal/transcribe/subprocess.go` |
| Folder watcher | `internal/watcher/` |
| launchd plist templates | `scripts/launchd/` |
| Daemon install/uninstall | `Makefile` |
| Config (paths, engine selection) | `internal/config/config.go` |
| Archive data root | `~/.audio-archive/` |
| whisper.cpp model files | `~/.audio-archive/models/` |
| Inbox directory | `~/audio-inbox/` |
| Daemon logs | `~/.audio-archive/logs/{watch,worker}.{log,err}` |

---

### Previous session notes (2026-04-11 morning — retained for context)

Came back to a **stuck queue**: `./archive status` showed 13 pending, 4 running, 10 complete on the overnight batch that was supposed to process 9 recordings. Daemons were alive at 0% CPU; last `worker.err` activity was at 07:44:51 starting a transcribe on `r002-t1-7inch.prep.wav`. No Python subprocess alive beneath the Go worker. Classic pipe-deadlock.

**Root cause.** `faster-whisper` uses Python multiprocessing. When its parent is killed (OOM on long transcribes — we saw two of these in the batch log, including a `resource_tracker: leaked semaphore` warning), the multiprocessing pool workers can survive and keep the stdout pipe open. Go's `cmd.Wait` then blocks forever on a pipe-copy goroutine that never sees EOF. The 60-minute deadline in `pipeline/transcribe.go` *did* fire — but the cancel path couldn't actually return.

**Fix shipped** (commit "Fix transcribe worker hang when faster-whisper leaks grandchildren"). In `internal/transcribe/worker.go`:

- `cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}` — subprocess gets its own process group so Cancel can signal the whole tree.
- Custom `cmd.Cancel` that sends `SIGKILL` to `-cmd.Process.Pid` (process group), not just the direct child.
- `cmd.WaitDelay = waitDelay` (30s in prod) — bounds the time Wait will block on I/O pipes after the process is dead. This is the belt-and-suspenders for grandchildren that escape the group kill (e.g. anything `setsid`'d).
- Added `internal/transcribe/worker_test.go` with a regression test (`TestRun_GrandchildPipeHolderDoesNotHang`) that uses a fake python script spawning a `setsid`-detached grandchild holding stdout. Before the fix the test hangs until the grandchild self-terminates; after, it returns bounded in well under 2s.

**whisper.cpp cutover — done this session.** The pipeline now calls `transcribe.RunWhisperCpp` exclusively, and the Python worker has been removed from the tree entirely.

- Installed `whisper-cpp 1.8.4` via Homebrew. Binary at `/opt/homebrew/bin/whisper-cli`. Downloaded `ggml-base.en.bin` (141 MB) and `ggml-silero-v5.1.2.bin` (864 KB VAD model) into `~/.audio-archive/models/`.
- **Benchmark on r005 sermon** (the canary from the overnight batch): **1m 41s wall clock** under whisper.cpp + Metal vs **56m 21s** under faster-whisper — a **~33× speedup**, far better than the 3–5× we projected. Quality parity: 11578 words (whisper.cpp) vs 11596 words (faster-whisper) — within 0.2%. Duration coverage: 4148.58s of the 4165.54s file (99.6%).
- **VAD parity canary on accordion file** (`r004-accordian-school-and-performances-1`, 35 min): faster-whisper with VAD emitted 0 words. whisper.cpp with VAD emitted 1 segment: `(upbeat music)`. Whisper's non-speech annotation, 2 words total, well under the summarizer's 20-word non-speech threshold — classification outcomes are identical. **Whisper.cpp's VAD is actually *more* informative** because the annotation gives the summarizer a stronger non-speech signal than an empty transcript.
- **Live production verification**: after the cutover, the daemons processed the next accordion file (`2026-04-11_r004-accordian-school-and-performances.prep.wav`, the combined tape ~70 min) through the full pipeline. The worker log confirms `backend=whisper.cpp model=ggml-base.en.bin` on the transcribe stage.
- **`--vad` requires `--vad-model`.** Without the VAD model path, `whisper-cli` crashes with `ggml_abort`. The initial scaffolded wrapper didn't know this and would have failed on first real invocation; the cutover added `WhisperCppVADModel` to config and a Stat check in `RunWhisperCpp`.
- **Code cleanup shipped in the same session**:
  - Deleted `worker/transcribe.py`, `worker/requirements.txt`, and the entire `worker/` directory.
  - Deleted `internal/transcribe/worker.go` (the dead Python-path `Run` function).
  - Moved `Segment`/`Result` types into `internal/transcribe/types.go`.
  - Moved `waitDelay` + `applySubprocessSafety` into `internal/transcribe/subprocess.go` as a shared helper used by whisper.cpp (and any future backend).
  - Removed `PythonPath` and `WorkerPath` from `config.Config` and from `Default()`. Also removed the now-unused `findProjectRoot` helper.
  - Ported the grandchild-hang regression test (`TestTranscribeSubprocessSafety_GrandchildDoesNotHang`) from the Python `Run` wrapper to exercise `RunWhisperCpp` against a fake whisper-cli that spawns a setsid grandchild. Same proof, now against the live code path.
  - README updated: "Python 3 for the transcription worker" → "whisper.cpp (`brew install whisper-cpp`)", with the model download curls in the setup block.

**Other gaps surfaced today (not yet fixed):**

1. **Dispatcher has no predecessor-dependency check.** When `transcribe` fails permanently, the downstream `summarize` job is still claimed and burns its retry budget with "no transcript — transcribe first". Evidence: job 18 (summarize for rec 6) failed permanently after the rec-6 transcribe was killed during the hang. Fix would be a JOIN in the claim query: don't hand out a summarize until its recording has a transcript row, etc. Small SQL change in `internal/store/jobs.go`.

2. **Dispatcher marks jobs `running` at claim time, not execution time.** With a 1-worker pool and a buffered channel, N jobs can be in the `running` DB state while only 1 is actually being worked on. Cosmetic now, but will confuse future hang diagnosis once concurrency bumps to 2-3. Two options: (a) add a `claimed` intermediate state separate from `running`, or (b) move the DB transition to the worker goroutine instead of the dispatcher. Low priority until concurrency goes up.

3. **Graceful-shutdown context cancel is counted against retry budget.** When `make reinstall-daemons` shuts the worker down, any in-flight job gets a `context canceled` error and its attempt counter increments. If the job was already on its last attempt, this marks it permanently failed even though the cancellation wasn't the job's fault. Evidence: 2 innocent transcribe jobs were marked permanently failed during this session's reinstall. Fix: distinguish `context.Canceled` from other errors in the retry loop — treat cancellation as a reset, not an attempt. ~10-line change in `internal/jobs/manager.go`.

4. **Worker concurrency is still 1.** Now that transcribe is GPU-bound via Metal and finishes in ~1-5 minutes instead of tens of minutes, the whole pipeline is bottlenecked on prep and summarize running sequentially. Bumping the pool to 2-3 should nearly halve wall-clock time for batches. One-line change in the launchd plist (`ProgramArguments` or equivalent env var). DESIGN.md's Optimization roadmap already flagged this as the natural follow-up to whisper.cpp.

5. **launchd QoS class gotcha (fixed same session).** The worker daemon's plist originally had `ProcessType=Background`, which catastrophically throttled whisper.cpp on Metal. Fix committed in `1f8fac4`. Captured in the tripwires list below. Worth mentioning here because it lost us ~6 hours of compute between the cutover at ~10:42 and the fix at ~16:57 — every whisper.cpp transcribe during that window hit its 60-min deadline without completing. The first transcribe under the fixed plist was a 68 min lecture recording (r002 t2) which completed in 1m13.88s — matching the manual-shell benchmark within a few seconds.

### What is working end-to-end

The full "drop a file, get a searchable archive entry" flow is live:

1. Drop any supported audio file in `~/audio-inbox/` (wav, mp3, m4a, flac, aiff, aac, ogg, opus).
2. The **`watch` launchd daemon** detects it via fsnotify, waits for size stability, and ingests it via `pipeline.IngestFile`.
3. Prep / transcribe / summarize jobs are enqueued to a SQLite-backed job queue.
4. The **`worker` launchd daemon** processes jobs with retries, backoff, and crash recovery.
5. `archive list`, `archive show <id>`, `archive search <phrase>` let you browse the results.

Both daemons run under `launchd`, auto-start at login, and restart on crash. See `Makefile` targets `install-daemons`, `daemons-status`, `logs`, `uninstall-daemons`.

### What shipped in the most recent session

Thirteen commits on `main`, all pushed to `origin/main`. Highlights:

1. **Initial CLI + pipeline** — ingest, prep, transcribe, summarize, run, list, show, search.
2. **Background job manager** — goroutine worker pool, buffered channel, dispatcher polling SQLite, atomic claim via `UPDATE ... RETURNING`, crash recovery via `ResetStuckJobs`, retry backoff, context-based graceful shutdown.
3. **50+ tests, race-clean** — `internal/store/jobs_test.go`, `internal/jobs/manager_test.go`, `internal/summarize/engine_test.go`, `internal/watcher/watcher_test.go`. Includes a concurrent-worker atomicity test that hammers the manager with 4 workers × 40 jobs.
4. **Batch directory ingest** — `archive ingest-dir <dir> --recursive --run` with stability delay and hidden-file filtering.
5. **Generalized metadata structure** — `SermonSummary` → `RecordingSummary` covering 11 recording types (sermon, voicemail, phone_call, interview, meeting, musical_performance, audio_diary, lecture, broadcast, field_recording, other) with universal fields + a `type_specific map[string]any` for per-type extensions.
6. **Whisper hallucination fix** — VAD filter in the Python worker, speech-density hint to the classifier, non-speech branch that skips chunk/merge for empty transcripts, file-context hint. Fixed the accordion recording from "audio_diary about searching for music" to "field_recording: Accordion School and Performances".
7. **Folder watch daemon + launchd integration** — `archive watch` command using `fsnotify`, launchd plists for both `watch` and `worker`, `Makefile` targets for install/uninstall/status/logs.
8. **Wave 1 optimizations (today)**:
   - FFmpeg filter reorder: downsample to 16 kHz mono **first**, then highpass + loudnorm. Drops data by ~6x before the filter chain runs. Also dropped `silenceremove` (VAD handles it) and added `-threads 0`.
   - Prep timeout: 10 min → 60 min (long tapes were getting killed mid-ffmpeg).
   - Stage 3 extraction prompt shrunk from ~2,500 words to **613 words** via `TestExtractPromptSize` regression guard. Fixed the broken 14-minute summarize (prompt was overflowing Mistral's 8K context).
9. **Comprehensive docs** — this file (DESIGN.md), `docs/remanence-integration.md`, README with the inbox workflow, `Makefile` help, and an Optimization roadmap section that captures the whisper.cpp migration plan and proposed Quality and reliability wins.

### What's currently running

As of mid-morning 2026-04-11, the daemons are up on the **fixed** worker binary and grinding through the batch again. Post-`ResetStuckJobs` counts after the kick: 19 complete, 1 failed (rec-6 summarize, the fallout described above), 4 running, 30 pending. The pending count is higher than the original 9 because the watch daemon has picked up additional files from the inbox in the meantime. Still CPU-Whisper-bound on transcribe, so completion is still measured in hours — but every transcribe that finishes from this point on is running with the hang fix.

**First thing to do next session:**

```bash
./archive status   # see how the batch finished
./archive list     # see the processed recordings
make logs          # tail the daemon logs for anything unusual
```

Then spot-check quality by running `./archive show <id>` on a few entries. The interesting question: did the shrunken stage 3 extraction prompt produce good summaries under the new pipeline, or are there regressions? And: is there any sign of another pipe-hang, or did WaitDelay cover every case?

### Immediate next priorities

In rough order of value:

1. **Assess batch quality** (10 min). Look at the latest completed summaries. Which classifications are right? Which type_specific fields populated? Any entity extraction flakiness? Any broken summaries? This data tells you which of the below is most urgent.

2. **Bump worker concurrency to 2 or 3** (~5 min). Now that transcribe is GPU-bound on Metal and finishes in 1–5 min instead of 30–60 min, the pipeline is bottlenecked on prep (CPU) and summarize (GPU via Ollama) running sequentially. A multi-worker pool lets prep and transcribe and summarize on different recordings overlap. One-line change in the launchd plist or the manager's `workers` constant.

3. **Dispatcher predecessor-dependency check** (~20 min). The rec-6 cascade today showed `summarize` being claimed before its `transcribe` completed and burning its retry budget. Fix the claim SQL in `internal/store/jobs.go` so dependents aren't eligible until their predecessors are in `complete` state.

4. **Don't count `context.Canceled` as a retry attempt** (~10 min). Graceful shutdown shouldn't eat the retry budget. Two transcribe jobs were falsely marked permanently failed during this session's `make reinstall-daemons` for this reason. Fix in `internal/jobs/manager.go`.

5. **Deterministic Bible reference extraction** (~60 min). Documented under [Quality and reliability wins](#quality-and-reliability-wins). Pure regex + canonical book list. Fixes the 1-to-10 references per run flakiness.

6. **Confidence scoring + `needs_review` flag**. Makes "honest degradation" concrete by flagging sketchy outputs and gating remanence auto-upload. Do this before the remanence integration.

7. **Remanence integration**. The north-star feature. Sketched in [remanence-integration.md](remanence-integration.md). Should use the `needs_review` flag from step 6.

Everything beyond this is in [Future work](#future-work).

### Key tripwires to remember

- **The `NeedsReview` struct field does NOT exist yet** — despite being mentioned in the Quality and reliability wins section as a proposal. If you grep for it in the code, you won't find it. The code block under that item is explicitly marked `// PROPOSED — not yet present on the struct`.
- **whisper.cpp is the only transcribe backend now.** The Python worker and `faster-whisper` are gone — `worker/` is deleted, `PythonPath`/`WorkerPath` are removed from config, and the pipeline calls `transcribe.RunWhisperCpp` directly. If you reintroduce a Python path for any reason, you'll be re-fighting the multiprocessing pipe-deadlock bug that cost us the 2026-04-10 overnight batch.
- **`applySubprocessSafety` in `internal/transcribe/subprocess.go` is load-bearing.** The `Setpgid` + custom `Cancel` + `WaitDelay` trio is what keeps whisper-cli (or any future backend) from hanging Go's `cmd.Wait` forever if a child leaks file descriptors. `TestTranscribeSubprocessSafety_GrandchildDoesNotHang` in `subprocess_test.go` is the regression guard. If you refactor the helper, re-run that test first.
- **`ProcessType=Background` MUST NOT be set on the worker launchd plist.** macOS's `Background` QoS pins the process to E-cores, deprioritizes its GPU scheduling, and starves it of memory bandwidth. On 2026-04-11 immediately after the whisper.cpp cutover, this single plist setting caused whisper-cli to run ~200× slower under the daemon than it did from a normal shell on the same file (manual: 11.78s on a 47-min file; daemon: 60-min deadline without completing, both retries). Every whisper.cpp transcribe since the cutover was hitting the deadline until the plist was fixed. The worker template now carries a deliberately loud comment explaining why. The watch daemon keeps `ProcessType=Background` because its workload is fsnotify-blocked I/O and it never needs P-cores — so don't copy-paste the worker plist onto another daemon without thinking about what it does.
- **Run-to-run LLM variance is real** — Mistral 7B at temperature 0.2 is not deterministic. The same file re-summarized twice will produce different entity lists, different bible reference counts, different titles. This is a known ceiling, not a bug. See [What's solid vs what's flaky](#whats-solid-vs-whats-flaky).
- **Context overflows are silent** — the reason stage 3 took 14 minutes earlier was that the prompt + content exceeded Mistral's 8K context window, causing sliding-window reprocessing. The `TestExtractPromptSize` test in `internal/summarize/engine_test.go` is a regression guard against this specific class of bug. If you grow the prompt template, that test will fail first.
- **`SetMaxOpenConns(1)` on the SQLite connection is load-bearing** — it eliminates SQLITE_BUSY errors from concurrent writes. Don't remove it even if the WAL mode comment makes it look unnecessary.

### Quick reference to where things live

| What | Where |
|---|---|
| CLI entry point | `cmd/archive/main.go` |
| Pipeline logic (pure functions) | `internal/pipeline/` |
| Job manager + handlers | `internal/jobs/` |
| SQLite store + migrations | `internal/store/` |
| Summarization engine + prompts | `internal/summarize/` |
| Folder watcher | `internal/watcher/` |
| whisper.cpp wrapper (active transcribe backend) | `internal/transcribe/whispercpp.go` |
| Shared transcribe types (`Result`, `Segment`) | `internal/transcribe/types.go` |
| Subprocess safety (process group + WaitDelay) | `internal/transcribe/subprocess.go` |
| whisper.cpp model files | `~/.audio-archive/models/` |
| launchd plist templates | `scripts/launchd/` |
| Daemon install/uninstall | `Makefile` |
| Config (paths, model names) | `internal/config/config.go` |
| Archive data root | `~/.audio-archive/` |
| Inbox directory | `~/audio-inbox/` |
| Daemon logs | `~/.audio-archive/logs/{watch,worker}.{log,err}` |

---

## What and why

**audio-archive** is a local-first pipeline for ingesting, preparing,
transcribing, summarizing, and searching digitized audio recordings. It was
originally built to archive sermon recordings from cassette and reel-to-reel
tapes but has since been generalized to handle any recording type.

tapes but has since been generalized to handle any recording type:
voicemails, audio diaries, interviews, meetings, musical performances, field
recordings, etc.

**Stack summary (post 2026-04-11 whisper.cpp cutover):** Go end-to-end, no
Python anywhere in the tree. Speech-to-text runs through `whisper.cpp`
(Metal-accelerated on Apple Silicon). Summarization runs through `Ollama`
over local HTTP. FFmpeg handles audio prep. SQLite with FTS5 holds records
and the job queue.

**Why it exists:**

- **Personal archive.** A real pile of digitized tape recordings needs to
  become searchable and browsable.
- **Go learning.** The project is an excuse to build real systems engineering
  experience in Go: goroutines, channels, context cancellation, SQLite,
  file system events, launchd integration, HTTP clients, structured
  concurrency.
- **Local-only.** Everything runs on a single Mac. No cloud APIs, no
  subscriptions, no data leaving the machine. Speech-to-text uses
  `whisper.cpp` invoked as a per-recording subprocess. Summarization uses a
  local LLM (Mistral or similar) via Ollama over HTTP.

The **north-star goal** is a "drop it and forget it" archive: drop an audio
file in `~/audio-inbox/` and it shows up in a searchable, browsable catalog
(eventually pushed to [remanence-archive](remanence-integration.md) for
web browsing) without any manual commands. As of April 2026, the local
part of that flow is working. The upstream push to remanence is future
work.

## Goals and non-goals

**Goals:**

- Zero manual intervention once set up
- Original master files are never modified (the archive keeps its own copy)
- Everything runs locally on a single Mac
- Pipeline stages are independently retriable and resumable
- Structured metadata that enables future search/browse features
- Go is the primary system language; Python is used only where necessary
  (speech-to-text)
- Honest degradation: when the LLM or Whisper produces garbage, the
  system should notice and not pretend otherwise

**Non-goals:**

- Cross-platform support (Linux/Windows). Designed for macOS. Would work
  on Linux with small changes but that's not a target.
- Scale beyond a single user's personal archive. No multi-tenant, no
  auth, no distributed workers.
- Real-time processing. Audio is batch-processed; latency of minutes is
  fine.
- Perfect transcription or summarization. The tools we use (Whisper,
  Mistral 7B) have real limits. We accept imperfect output and focus
  on not making it *worse* than the underlying models.

## Architecture overview

```
File dropped in ~/audio-inbox/
            │
            ▼
   watch daemon (Go, launchd)          [internal/watcher/]
   ─ fsnotify for real-time events
   ─ periodic sweep as backup
   ─ file size stability check
            │
            ▼
   pipeline.IngestFile                 [internal/pipeline/]
   ─ copy master to archive
   ─ extract metadata via ffprobe
   ─ create DB record
            │
            ▼
   Job queue (SQLite)                  [internal/store/jobs.go]
   ─ jobs: prep / transcribe / summarize
   ─ atomic claim via UPDATE...RETURNING
   ─ retry backoff on failure
            │
            ▼
   worker daemon (Go, launchd)         [internal/jobs/manager.go]
   ─ goroutine pool, buffered channel
   ─ dispatcher polls DB every 2s
   ─ graceful shutdown on SIGINT
            │
     ┌──────┼──────┐
     ▼      ▼      ▼
   prep  transcribe summarize
     │      │      │
     ▼      ▼      ▼
  FFmpeg  whisper. Ollama              [internal/audio/, /transcribe/, /summarize/]
          cpp      Mistral 7B
          +Metal   over HTTP
            │
            ▼
     SQLite with FTS5 for search
     + .txt / .json / .meta.json files on disk
```

## Pipeline stages

### 1. Ingest (`pipeline.IngestFile`)

**What it does:** Takes a source audio file, copies it to
`~/.audio-archive/masters/YYYY/{date}_{slug}_{speaker}.{ext}`, probes
metadata via `ffprobe`, and creates a `recordings` row in SQLite.

**Why it's a separate stage:** The master file is the source of truth.
Everything else (prep, transcripts, summaries) can be regenerated from it.
Losing a master is unrecoverable; losing anything else is a re-run away.

**Idempotency:** Running ingest twice on the same file returns
`Skipped: true` without error. This is critical for the watcher, which
may see the same file multiple times (via fsnotify + periodic sweep).

### 2. Prep (`pipeline.PrepRecording` → `internal/audio/prep.go`)

**What it does:** Runs a single FFmpeg command that applies four filters
in order:

1. `highpass=f=80` — removes tape rumble, hum, and low-frequency noise
2. `loudnorm=I=-16:TP=-1.5:LRA=11` — EBU R128 loudness normalization
3. `silenceremove` — trims leading/trailing silence
4. `-ar 16000 -ac 1` — downsamples to 16 kHz mono (Whisper's preferred input)

**Why those filters:** Old tape recordings have inconsistent levels, tape
hiss, and dead air. Normalizing and filtering before Whisper meaningfully
improves transcription accuracy without changing the underlying content.
The master is never touched — the prepped version lives in
`~/.audio-archive/processed/`.

### 3. Transcribe (`pipeline.TranscribeRecording` → `transcribe.RunWhisperCpp`)

**What it does:** Spawns `whisper-cli` as a subprocess, passing the
prepped audio file, a GGML speech model, a Silero VAD model, and an
`--output-file` path for the JSON output. When the subprocess exits the
Go side reads the JSON file, parses it into the `Result` shape, and
saves it to the database and to `.txt` / `.json` files. On Apple
Silicon whisper.cpp uses Metal for the decoder matmuls, making
transcribe GPU-bound rather than CPU-bound.

**Why whisper.cpp specifically (as of 2026-04-11):** Native C++, Metal
acceleration on Apple Silicon, same Whisper model weights as every
other implementation, a single-file JSON output format, and — critically
— a single process tree with no Python interpreter and no multiprocessing
pool to leak grandchildren. Benchmarks on a 69-minute sermon: 1m41s under
whisper.cpp+Metal vs 56m21s under the prior faster-whisper path (~33×).

**Critical detail — VAD (voice activity detection):** The invocation
passes `--vad --vad-model <silero>`. Without the VAD model file,
`whisper-cli` aborts with `ggml_abort`. Without VAD at all, Whisper
hallucinates repeated phrases on non-speech audio. See
[Whisper hallucinations](#whisper-hallucinations-on-non-speech) below.

**Subprocess safety.** The `exec.Cmd` used for whisper-cli is configured
by `applySubprocessSafety` from `internal/transcribe/subprocess.go`,
which sets a new process group, a custom `Cancel` that SIGKILLs the
whole group, and `WaitDelay=30s` so Go's `cmd.Wait` can't block forever
if a grandchild leaks a pipe fd. This is the regression guard for the
2026-04-10 hang that took down the overnight batch. See
[Crash recovery across all stages](#crash-recovery-across-all-stages).

### 4. Summarize (`pipeline.SummarizeRecording` → Ollama)

**What it does:** Runs a three-stage pipeline against a local LLM (Mistral
by default via Ollama's HTTP API):

1. **Chunk summarization.** If the transcript is longer than the model's
   context budget, split it into overlapping chunks and summarize each
   into ~3 paragraphs. The per-chunk prompt explicitly demands preservation
   of proper nouns, dates, numbers, and quotes.
2. **Merge.** Combine the chunk summaries into a single 4-6 paragraph
   narrative summary.
3. **Classify + extract.** Using the merged summary plus the raw chunk
   summaries plus an audio-signal hint plus the file metadata, classify
   the recording type (sermon, voicemail, musical_performance, etc.) and
   extract structured JSON metadata.

**Why three stages:** Asking a 7B model to do everything at once produces
garbage. Decomposing the problem (summarize sections → merge → extract
structure) gives the model a more tractable task at each step and makes
JSON parse failures recoverable. See
[LLM classification and extraction](#llm-classification-and-extraction)
below.

**Output:** A `RecordingSummary` with universal fields (topics, tags,
people, places, etc.) plus a `type_specific` map containing fields
appropriate to the classified type (bible_references for sermons,
callback_requested for voicemails, pieces for musical performances,
etc.). Schema lives in `internal/summarize/types.go`.

## Design decisions

### Go is the only language; subprocess everything else

Every stage is written in Go:
- CLI and command parsing (Cobra)
- Job orchestration (custom worker pool in `internal/jobs/`)
- Database access (`modernc.org/sqlite` — pure Go, no CGo)
- FFmpeg invocation (`os/exec`)
- whisper-cli invocation (`os/exec`, `internal/transcribe/whispercpp.go`)
- HTTP client for Ollama
- File system watcher (`fsnotify`)
- Pipeline coordination

Prior iterations had a small Python worker for `faster-whisper`, but that
path is gone: whisper.cpp is a native binary with no interpreter to
manage, the 33× transcribe speedup comes for free with Metal, and the
entire class of multiprocessing-pipe-deadlock bugs that bit us on the
2026-04-10 overnight batch disappears by construction. There is no
Python in the tree. Every external tool is invoked as a one-shot
subprocess from Go, all I/O is protected by the shared
`applySubprocessSafety` helper, and the systems programming surface is
100% Go.

### SQLite, not Postgres

SQLite with WAL mode is the entire data layer. Single file, zero ops,
built-in FTS5 for transcript search. No connection pool needed — we
serialize all writes through `SetMaxOpenConns(1)` which eliminates
SQLITE_BUSY errors when dispatcher and workers hit the DB concurrently.
WAL still lets readers run without blocking the writer.

Could migrate to Postgres later via the existing `internal/store/`
repository layer, but there's no reason to.

### Jobs are SQLite rows, not channels

The job queue lives in the `jobs` table, not in an in-memory Go channel.
This gives crash recovery for free: if the worker process dies
mid-execution, the DB still knows what was pending, running, or failed.
On startup, the worker calls `ResetStuckJobs` which moves any `running`
jobs back to `pending` for retry.

The Go channel inside the Manager is just the pipe between the dispatcher
goroutine and the worker goroutines — it's ephemeral and rebuilt on every
worker start.

### Pipeline logic as pure functions

`internal/pipeline/` contains `IngestFile`, `PrepRecording`,
`TranscribeRecording`, and `SummarizeRecording` as pure functions that
take `(ctx, cfg, db, recordingID)` and return a result or error. Both the
CLI commands and the job handlers call these — no duplicated logic.

This means the CLI `archive prep 5` and the async worker processing a
`prep` job run literally the same code path. Easier to reason about,
easier to test.

### RecordingSummary is universal, not sermon-specific

The first version of the summary type was `SermonSummary` with fields
like `bible_references` and `theological_themes` baked in. That made the
tool only useful for sermons.

The current `RecordingSummary` (defined in `internal/summarize/types.go`)
has:
- A `recording_type` field (classified by the LLM at extraction time)
- Universal fields that apply to any recording (topics, tags, people,
  places, quotes, dates, mood, etc.)
- A `type_specific map[string]any` that holds fields relevant to the
  classified type

This means dropping a voicemail into the archive produces
`{callback_requested: true, urgency: "high"}` in `type_specific`, while
a sermon produces `{bible_references: [...], scripture_focus: "..."}`,
all via the same code path and schema. Adding a new recording type is a
single-file change in `types.go`.

### Classify before extracting type-specific fields

Stage 3 of summarization is deliberately a single LLM call that does both
classification and extraction. Separating them (classify first, then a
second type-aware extraction call) would be cleaner but doubles the
latency and LLM cost. For Mistral 7B at ~1 minute per extraction, that's
a meaningful difference.

If/when quality plateaus, splitting to two passes is a known fallback.

### Watch daemon uses fsnotify + periodic sweep

The watcher subscribes to kernel-level file system events via fsnotify
(which wraps macOS FSEvents) for real-time response, AND runs a periodic
sweep every 60 seconds as a backup. The sweep catches:
- Files present in the directory when the watcher started
- Events fsnotify might drop under heavy load
- Edge cases where the kernel buffer filled up

fsnotify alone would be almost enough — but "almost" isn't good enough
for a system that's supposed to not need babysitting.

### File stability check before ingest

When a file appears, the watcher doesn't ingest it immediately. It waits
for the file's size to be unchanged for `StableDelay` (default 3 seconds)
before considering it ready. Also never declares a zero-byte file stable.
This handles tools like `say(1)`, Finder, and `cp` that create the
destination file at 0 bytes and stream content in afterward.

### launchd for daemon lifecycle

The watch and worker daemons are managed by macOS launchd via plist
files in `~/Library/LaunchAgents/`. launchd handles:
- Start at login (`RunAtLoad`)
- Restart on crash (`KeepAlive`)
- PATH setup (so `ffmpeg`, `whisper-cli`, and friends are found)
- Log file management

No custom daemon code, no PID file juggling, no systemd envy.

## Hard problems and how we handle them

### Whisper hallucinations on non-speech

**The problem.** When Whisper encounters audio without clear speech
(music, silence, ambient noise, white noise), it frequently falls into
a loop and produces made-up text — usually a phrase it repeats 50+
times. We discovered this when processing a 35-minute accordion
recording: Whisper transcribed 457 words of "I'm going to find an
exit march" repeated over and over. The LLM then classified the
recording as an `audio_diary` about someone searching for music,
inventing a narrative from the hallucinated text.

**How we handle it.** Three layers:

1. **VAD filter in Whisper.** `vad_filter=True` with Silero VAD runs
   voice activity detection before transcription and skips non-speech
   regions entirely. After enabling VAD, the accordion recording
   produces 0 transcribed words instead of 457 hallucinated ones.

2. **Speech density hint to the classifier.** The summarizer computes
   words-per-minute from the transcript length and audio duration, and
   passes it to the stage 3 extraction prompt. Normal speech is ~140 wpm;
   sermons are ~120 wpm; sparse is <40 wpm; minimal is <10 wpm. The
   classifier uses this as a signal: "this 35-minute recording produced
   only 0 words — classify it as non-speech content even if the transcript
   is empty."

3. **Non-speech branch in the summarizer.** When the transcript has
   fewer than 20 words, the engine skips chunk summarization and merge
   entirely, synthesizing a placeholder ("this recording has no
   transcribed speech; it is N minutes long; probably non-speech") and
   going straight to classification. Saves ~30 seconds of wasted LLM
   work per non-speech file.

Together these turned the accordion file from `audio_diary: "Search for
an Exit March"` into `field_recording: "Accordion School and Performances"`.

### LLM classification and extraction

**The problem.** Mistral 7B is capable but inconsistent. Run-to-run
variance is real: the same prompt on the same transcript can produce
different entity lists, different numbers of bible references, and
occasionally different classifications. Stricter prompts help but don't
eliminate it.

**How we handle it.**

1. **Structured output via Ollama's `format` parameter.** We pass a
   JSON schema to Ollama which constrains the generation. Every
   universal field is marked required, so the model cannot silently
   omit fields — it must emit empty strings or empty arrays instead.

2. **Retry + repair for malformed JSON.** Stage 3 tries up to 3 attempts.
   Attempts 1-2 re-run the extraction prompt. Attempt 3 feeds the
   previously-returned broken JSON back into a dedicated repair prompt:
   "here's some broken JSON, fix it."

3. **Dual-source extraction.** Stage 3 receives BOTH the merged narrative
   summary AND the raw chunk summaries. The merged summary is good for
   topics and flow; the chunks are good for exhaustive entity extraction
   (they retain details the merge phase sometimes compresses away).

4. **Defensive normalization.** After parsing, we:
   - Coerce nil slices to empty slices (so JSON never marshals `null`)
   - Strip placeholder values ("Unknown", "N/A", "none", "") from
     fields that should be empty strings instead
   - Lowercase and hyphenate all tags
   - Flatten `type_specific` if the model nested fields under a key
     named after the recording type (a common Mistral quirk)
   - Recursively clean "Unknown" values from nested `type_specific`
     values

5. **File metadata as a classification signal.** The file's title and
   source filename are passed to the extraction prompt as an
   "audio signal hint" alongside the speech density. This lets the
   classifier use filename clues ("accordion-school-and-performances")
   even when the transcript is absent or ambiguous.

**Known ceiling.** Even with all of the above, entity extraction
quality depends on what Mistral 7B can reliably do. Sometimes it picks
up every proper noun in a transcript; sometimes it drops them. The
current prompt is at roughly the limit of what prompt tuning can
achieve on this model. Further improvement requires either:
- Switching to a stronger model (llama3.1:8b, gemma2:9b)
- Deterministic proper-noun preprocessing (regex out capitalized words
  from the transcript and inject them as "these must appear in the
  output")
- A second dedicated extraction pass for entities only

None of these are implemented yet — see [Future work](#future-work).

### Long transcript chunking

**The problem.** A 60-minute sermon is ~10,000-12,000 words. That doesn't
fit in Mistral's 8K context window even before accounting for the prompt
template and the response budget. We need to split it up without losing
context at the boundaries.

**How we handle it.** `ModelProfile.ChunkBudget()` computes how many words
of transcript fit in a single call:

```
available_tokens = context_window - prompt_overhead(500) - response_reserve(1024)
chunk_words = available_tokens / tokens_per_word(1.3)
```

For Mistral's 8K context, that's ~5,130 words per chunk. Chunks overlap
by 200 words so named entities mentioned near a boundary don't get cut
in half.

Each chunk gets its own summarization call in stage 1. The results are
concatenated into an ordered list of "Section N of M" summaries which
feed stage 2 (merge). This is classic map-reduce summarization.

Adding a new model is just a new entry in the `ModelProfiles` map.
Unknown models fall back to a conservative 4K context estimate.

### File is still being copied when the watcher sees it

**The problem.** Dropping a file into the inbox is not atomic. Finder
creates the target file at zero bytes, then streams the content in.
fsnotify fires a Create event immediately, but the file isn't ready.
Ingesting it at that moment would archive an empty file.

**How we handle it.**

1. **Stability delay.** The watcher tracks each pending file's size
   and the timestamp of the last size change. A file is only considered
   ready when its size has been stable for `StableDelay` (default 3s).
2. **Zero-byte rejection.** A file at 0 bytes is never declared stable,
   regardless of how long it's been sitting there. Defensive against
   tools that create a placeholder and never write to it.
3. **Re-stat before ingest.** Even after the stability delay elapses,
   the watcher does a fresh `os.Stat` before ingesting, to catch any
   last-second changes.
4. **In-memory processed set.** Files already ingested in this watcher
   session are skipped on subsequent sweeps, avoiding re-trigger loops.
5. **Hidden file filter.** Dotfiles, `.tmp`, `.part`, `.crdownload`,
   `._metadata` (macOS), and `file~` backups are all ignored.

### Crash recovery across all stages

**The problem.** Worker process dies mid-job. What happens?

**How we handle it.**

1. **Job state lives in SQLite.** When a worker claims a job, it's
   atomically marked `running` via `UPDATE ... RETURNING`. If the
   process dies, the row stays in `running` state.
2. **`ResetStuckJobs` on startup.** The manager's `Run()` method
   begins by resetting every `running` job back to `pending`. This
   means whatever was in flight when the worker died gets picked up
   again on the next start.
3. **Attempt counter.** Each claim increments `attempt`. Jobs have a
   `max_retries` budget per type (3 for prep, 2 for transcribe and
   summarize — the latter two are expensive). Hitting the budget
   moves the job to terminal `failed` status.
4. **Retry backoff.** Failed jobs set `finished_at` to "now" and the
   claim query skips jobs whose finished_at + (attempt * 30s) is in
   the future. This spaces out retries without blocking other jobs.
5. **Graceful shutdown.** On SIGINT, the manager's context cancels.
   The dispatcher stops polling and closes the jobs channel. Workers
   finish their current job and exit. A `sync.WaitGroup` makes `Run()`
   block until all workers are done.
6. **Idempotency at each stage.** Prep is idempotent (checks if the
   prep file already exists). Ingest is idempotent. Transcribe and
   summarize overwrite, which is fine. So retries after a partial
   success don't produce duplicates.

## What's solid vs what's flaky

### Solid

- **Ingest and idempotency.** Re-running on the same file is always
  a no-op. Tested end-to-end, covered by the pipeline and CLI.
- **FFmpeg prep.** Filter chain is deterministic; any bugs would be
  instant and obvious. Not a source of variance.
- **Job manager correctness.** Covered by 11 manager tests including
  4 concurrent workers × 40 jobs with no double-dispatch. Context
  cancellation, graceful shutdown, retry backoff, and crash recovery
  all have tests.
- **SQLite job store atomicity.** `UPDATE ... RETURNING` is atomic;
  the single-connection setup prevents SQLITE_BUSY entirely. Covered
  by the `IsAtomic` test with 10 concurrent goroutines.
- **Watch daemon lifecycle.** Starts, watches, ingests, shuts down
  cleanly. launchd handles restarts. Tested manually end-to-end.
- **Chunk budget math.** Deterministic, unit-tested. A new model with
  a larger context window is a one-line addition.

### Mostly solid with known quirks

- **Transcription quality with VAD.** VAD eliminates the hallucination
  loops. Real speech is transcribed accurately with the `base` model.
  Rare edge: Whisper still produces occasional weird substitutions
  on muffled or accented speech (acceptable).
- **Classification.** File metadata, speech density, and transcript
  content are all passed to the classifier. For clearly-labeled files
  (title "Voicemail" → voicemail) the classification is reliable.
  For ambiguous cases (e.g. a concert field recording that's also a
  musical performance), it's a judgment call.
- **Chunk + merge summarization.** Produces readable narrative
  summaries that usually capture the arc of the recording.

### Flaky / run-to-run variable

- **Entity extraction density.** People, places, and organization
  fields sometimes populate, sometimes don't, even on the same input.
  Known ceiling of Mistral 7B at temperature 0.2. See
  [LLM classification and extraction](#llm-classification-and-extraction).
- **Voicemail type_specific field coverage.** `callback_requested` and
  `urgency` populate reliably; `recipient` and `caller_identity` are
  hit-or-miss depending on whether the model picks up the right signals
  from the transcript.
- **Sermon bible reference count.** Varies from 1 to 10 references per
  run on the same transcript. The current prompt tells the model to
  "scan for every book chapter:verse pattern" but Mistral's compliance
  is inconsistent.
- **Run-to-run determinism.** Even at low temperature, Mistral produces
  different outputs on the same inputs. Not a correctness issue but a
  UX quirk — users may see slightly different metadata if they
  re-summarize.

### Known rough edges / small annoyances

- **Suggested titles sometimes hallucinate dates.** "Voicemails with
  Martin (April 10 - April 16)" when only relative weekdays were in
  the transcript. The prompt explicitly forbids this; the model does
  it anyway sometimes.
- **The `people` field sometimes gets "Speaker" as a placeholder**
  instead of the actual name, when the model overcorrects.

## Optimization roadmap

Performance-focused future work, captured here so the plan doesn't get
lost across sessions. Wave 1 has been shipped (FFmpeg filter reordering,
prep timeout, extraction prompt shrinkage). The items below are the
bigger wins still on the table.

### Switch Whisper to `whisper.cpp` with Metal ✅ SHIPPED 2026-04-11

**Status:** **Done.** **Actual effort:** ~90 minutes including the
install, benchmark, integration, cleanup, and docs. **Actual speedup:**
**~33×** on transcription — r005 sermon went from 56m21s (faster-whisper,
CPU int8) to 1m41s (whisper.cpp, Metal). Significantly better than the
3–5× we projected going in.

Quality parity at the canary level: 11578 words vs 11596 (within 0.2%).
VAD parity on the accordion file: whisper.cpp emits 1 segment
`(upbeat music)` vs faster-whisper's 0-word output, both staying under
the 20-word non-speech threshold in the summarizer. Cutover verified
in production via the live daemons processing the combined accordion
tape through the new pipeline.

Original plan preserved below for the historical record. See the
2026-04-11 session handoff at the top of this file for the actual
cutover notes.

---

**Original status (pre-cutover):** not yet implemented. **Estimated effort:** 60-90 minutes.
**Expected speedup:** 3-5x on transcription, which is the dominant
bottleneck for long speech-heavy recordings. Changes a 70-minute sermon
transcribe from ~12-15 minutes to ~3-4 minutes.

**The problem.** The current transcription worker uses `faster-whisper`,
which is a Python binding to `CTranslate2`. CTranslate2 supports CPU and
CUDA but **not Metal**. On Apple Silicon, faster-whisper runs entirely
on the CPU with int8 quantization, achieving ~2-5x realtime. That's
slow, AND it leaves the 14-16 core Apple GPU completely idle during
every transcription.

**The fix.** Swap the Python worker for `whisper.cpp`, a native C++
reimplementation of Whisper that uses Metal for matrix operations on
Apple Silicon. Same Whisper model weights, same decode algorithm —
just a different runtime that actually uses the GPU.

**Why `whisper.cpp` specifically (over `mlx-whisper`):**

- `whisper.cpp` is a standalone CLI, not a Python library. Swapping to
  it eliminates Python from the transcription path entirely, aligning
  with the "Go primary, Python minimized" design principle. The Python
  venv (`worker/transcribe.py`, `worker/requirements.txt`, `.venv/`)
  can be deleted.
- It's battle-tested — it powers a huge number of production tools.
- `brew install whisper-cpp` is a single command.
- Faster startup per invocation (no Python interpreter startup, no
  library import time). Matters for short files.
- `mlx-whisper` is slightly newer and Python-based; the speed is
  comparable but the "no more Python" benefit of `whisper.cpp` is a
  meaningful simplification for this project.

**Implementation plan:**

1. **Install and benchmark.** `brew install whisper-cpp`. Download a
   base model from HuggingFace (e.g.
   `ggml-base.en.bin` from `ggerganov/whisper.cpp`). Run it against one
   of the real tape recordings and compare quality + speed against the
   current pipeline on the same file. Confirm the expected speedup.

2. **Model management.** Decide where model files live. Options:
   - Bundled: ship a small model with the repo (too big for git).
   - User-provided path: `WhisperCppModel` in config, user downloads once.
   - Auto-download on first use: `archive` detects missing model and
     fetches from HuggingFace.
   Recommendation: user-provided path stored under
   `~/.audio-archive/models/`, with an `archive install-models` CLI
   convenience command that downloads defaults.

3. **New Go wrapper.** Replace `internal/transcribe/worker.go`. Instead
   of `exec.CommandContext(python, workerPath, ...)`, call
   `exec.CommandContext(whisperBin, --model, modelPath, --file,
   audioPath, --output-json, --beam-size, 5, ...)`. Parse
   whisper.cpp's JSON output into the existing `transcribe.Result`
   struct (downstream code doesn't change).

4. **VAD support.** `whisper.cpp` has VAD via `--vad` and
   `--vad-model` flags. Must verify it prevents the same Whisper
   hallucination-on-non-speech behavior we fixed in Wave 1 (the
   accordion recording test case). If VAD isn't as effective, may
   need to pre-process with FFmpeg silence detection, or keep the
   post-transcribe repetition detector as a safety net.

5. **Config updates.** Replace `PythonPath` and `WorkerPath` fields in
   `config.Config` with `WhisperCppBin` (default
   `/opt/homebrew/bin/whisper-cli`) and `WhisperCppModel` (default
   `~/.audio-archive/models/ggml-base.en.bin`). Update
   `config.Default()`.

6. **Cleanup.** Delete `worker/transcribe.py`,
   `worker/requirements.txt`, the `worker/` directory entirely.
   Remove Python venv references from README, Makefile, and
   `internal/pipeline/transcribe.go`. Update DESIGN.md to reflect
   the "no Python at all" architecture.

7. **Test end-to-end.** Re-process one of the archived test recordings
   through the full pipeline with the new worker. Verify:
   - Transcript quality is equal or better
   - Timing is dramatically faster
   - The VAD still prevents hallucinations on the 35-minute accordion
     file (our canary for non-speech audio)

**Risks and trade-offs:**

- **Model file format.** faster-whisper downloaded models automatically
  in its own format; whisper.cpp uses GGML `.bin` files which are a
  separate download. One-time friction for the user.
- **Slightly different defaults.** whisper.cpp's CLI has different
  default temperature fallback, beam search, etc. Output may differ
  subtly from faster-whisper on ambiguous speech. Neither is "better"
  — just different.
- **VAD parity.** If whisper.cpp's VAD isn't as robust as faster-whisper's
  Silero integration, we may need additional safeguards against
  hallucination loops. Plan for this explicitly during testing.
- **Model download in CI / fresh install.** An `archive install-models`
  convenience command is worth the 30 minutes to build since manual
  curl-from-HuggingFace is a bad onboarding experience.

**Why we haven't done it yet:** Wave 1 fixes (filter reorder, prompt
shrink) gave the biggest immediate wins with lowest risk. The Whisper
swap is a bigger refactor that deserves a dedicated session with fresh
context, good baseline numbers from the Wave 1 pipeline to compare
against, and time to properly validate the VAD behavior on non-speech
files.

### Other performance wins

These are smaller but still worthwhile, roughly in order of value:

- **Worker concurrency = 2 or 3.** (Now unblocked by the whisper.cpp
  cutover.) With transcribe moved to Metal GPU, the three stages use
  three separate resources (prep = CPU+FFmpeg, transcribe = Metal GPU
  via whisper.cpp, summarize = GPU via Ollama). Bumping concurrency to
  2–3 lets different recordings progress through different stages in
  parallel for a 30–50% batch speedup.
  One-line change in the launchd plist. Best done *after* the
  whisper.cpp swap.

- **Deterministic proper-noun preprocessing.** Regex capitalized words
  out of the transcript and inject as "these must appear in
  people/places/organizations" to the stage 3 prompt. Eliminates
  entity extraction variance without model changes. ~50 lines of Go.

- **Two-pass stage 3 extraction.** Split into "classify + universal"
  (small focused prompt) and "type-specific" (small prompt showing
  only the field guide for the classified type). Doubles the LLM call
  count but each call is fast and focused, and quality usually
  improves because the model isn't juggling everything at once.

- **Opportunistic prep skip.** If a source file is already 16 kHz mono
  and within a reasonable loudness range, skip the loudnorm pass
  entirely. Would make prep near-instant for most modern recordings
  while preserving the heavy work for tape digitizations.

- **Larger-context LLM.** Try `mistral-nemo` (128k context) as a
  drop-in replacement for mistral. More headroom for future prompt
  additions without hitting context window issues. Same speed per
  token. ~2x the RAM usage (~7 GB loaded vs ~4.5 GB).

### Quality and reliability wins

> **Status of this entire subsection: none of these items are implemented yet.**
> All four are proposals. No code exists for `NeedsReview`, no regex
> extractors exist, no snapshot test harness exists. This section captures
> the plan so a future session can pick it up.

Speed isn't the only ceiling. Entity extraction, title generation, and
reference counts are currently flaky because they rely on Mistral 7B
"noticing" facts in the transcript. The proposed direction is to
**shrink the surface area where LLM reliability matters** — do
deterministic extraction for the fields users will treat as factual,
and keep the LLM for narrative prose and broad classification where
variance is acceptable.

#### Deterministic Bible reference extraction

**Status:** not yet implemented. **Estimated effort:** ~60 minutes.

The proposal: a regex + canonical book-name list (including common
abbreviations like "1 Cor." and "Rev.") that finds every
`Book chapter:verse` pattern in a transcript with near-zero false
positives. Run this extractor in Go, store the results directly on the
summary, and let the LLM only identify the *primary* scripture focus
(which is a judgment call) rather than trying to enumerate all
references (which is a counting problem it fails at).

This would be a smaller-surface-area, higher-reliability version of
the deterministic proper-noun extraction idea, and arguably should
ship first since the grammar is more constrained. It would directly
fix the "1-to-10 references on the same input" flakiness noted in the
known-flaky section.

#### Template-based title generation

**Status:** not yet implemented. **Estimated effort:** ~30 minutes once
the universal extraction fields are reliable.

The proposal: stop asking the LLM to "generate a title" freeform (which
is why we see hallucinated date ranges like "Voicemails with Martin
(April 10 - April 16)"). Replace with type-aware templates that compose
from already-extracted fields:

- voicemail → `"Voicemail from {caller}"` or `"Voicemail for {recipient}"`
- sermon → `"{speaker} — {scripture_focus}"` or `"{series} — {theme}"`
- musical_performance → `"{source_title}"` or `"{ensemble_type} — {piece}"`
- field_recording → `"{source_title}"` or inferred setting
- fallback → source filename stem

This would eliminate an entire class of hallucination without needing
better models or better prompts.

#### Confidence scoring + `needs_review` flag

**Status:** not yet implemented. **Estimated effort:** ~90 minutes
including rule implementation and test coverage. No `NeedsReview` or
`ReviewReasons` fields exist on `RecordingSummary` today — the proposal
below describes the additions.

The proposal: add new fields to `RecordingSummary`:

```go
// PROPOSED — not yet present on the struct:
NeedsReview   bool     `json:"needs_review"`
ReviewReasons []string `json:"review_reasons"`
```

Populate via deterministic rules after the LLM returns:

- Transcript too short relative to audio duration → review
- Entity arrays (people/places/orgs) empty on a long recording → review
- Title contains a date string not found verbatim in the transcript → review
- Repeated-phrase hallucination detected in the transcript → review
- Voicemail classification but no caller/recipient extracted → review
- LLM and regex scripture extraction diverge significantly → review

The flag would then be used to **gate remanence-archive uploads**:
items marked `needs_review: true` require explicit approval before
being pushed upstream. This matches the drafts-by-default design in
[remanence-integration.md](remanence-integration.md) and would make
the "honest degradation" goal in our design principles *concrete*
rather than aspirational.

#### Snapshot test harness

**Status:** not yet implemented. **Estimated effort:** ~2 hours to
pick recordings, commit snapshots, and wire up tolerance-based
comparison.

The proposal: pick ~10 representative recordings (a sermon, a
voicemail, a music recording, an audio diary, a field recording, etc.)
and commit an "expected-ish" JSON snapshot for each:

- Expected `recording_type` (exact match)
- Expected number range for `main_topics`, `tags`, `people`, etc.
- Expected `bible_references` count ± tolerance
- Expected title to match a regex pattern (not an exact string, since
  LLM output varies)
- `needs_review` flag expected state

Run the suite on every prompt change, model swap, or extraction
refactor. Compare against baseline before merging to prevent silent
regressions during optimization work. The accordion file and the
voicemail used during today's testing are natural starter cases since
we have real debug traces for both.

## Future work

Ordered roughly by value:

1. **Larger LLM comparison.** Test with `llama3.1:8b` and `gemma2:9b`
   via the existing Ollama client. Both should be better at
   instruction following than Mistral 7B. Drop-in change via
   `--model` flag. High info-per-dollar because it's basically free
   to try — worth doing early in any quality improvement push, since
   it tells us whether the remaining flakiness is a prompt ceiling or
   a model ceiling.

2. **Remanence integration.** Add a `sync` job type that uploads the
   prepared audio + transcript + metadata to remanence-archive via
   a new `POST /api/sync` endpoint. Design sketched in
   [remanence-integration.md](remanence-integration.md). Should use
   the `needs_review` flag (see Quality and reliability wins above)
   to block auto-upload for low-confidence items.

3. **iCloud Drive inbox.** Symlink `~/audio-inbox/` into iCloud Drive
   so you can drop files from your iPhone or iPad. They sync to the
   Mac, the watcher picks them up automatically. Zero code changes
   required.

4. **`archive browse` TUI.** Interactive browser to navigate
   recordings: filter by type/speaker/date, search transcripts,
   view summaries. Go has several TUI libraries (`bubbletea`,
   `tview`) that would suit this.

5. **Hallucination detection on transcripts.** Even with VAD, Whisper
   can still produce repeated phrases. Detect patterns like "same
   sentence repeated N times" as a post-processing quality check.
   Hooks naturally into the `needs_review` flag.

6. **Audio-level classification hint.** Run a simple music vs speech
   detector on the audio itself (not the transcript) as another
   classification signal. Tools like `librosa` or Go audio libraries
   could do this cheaply.
