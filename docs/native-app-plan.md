# Native macOS app: build plan

Replaces the Go CLI, launchd daemons and Next.js review app with one Swift app.
Written 2026-11-02. Mockups: https://claude.ai/artifact/Vec7wX1cEPYiuFKDuKfzE9

## Goal

Make the archive easy and a joy to use: record a tape, mark its tracks, read
along, and push it to the site, all from one Mac app. It's built for one user,
so there's no sandbox, App Store build or scale work.

## Decisions

| Area | Decision |
|---|---|
| Name | Remanence |
| Language | Swift only. Learning Go is no longer a goal. |
| Interface | SwiftUI, with AppKit where needed (long editable transcripts, waveforms) |
| Running | Single app with a menu bar item and login item, so work continues with the window closed |
| CLI | None |
| Audio tools | Keep `ffmpeg`, `whisper-cli` and `claude -p` as subprocesses, behind small interfaces |
| Summaries | Claude only. Ollama, chunking and merge code are dropped. |
| Outbox folders | Dropped; the app replaces them |
| Database | GRDB with versioned migrations and FTS5 |
| Recording | Always the untouched signal. The app warns about levels but never changes gain. |
| Track splits | Manual markers only for now. Nothing is cut until push. |
| Push | Upload only what the site doesn't already have, identified by content hash |

## Starting point

- **No old data to migrate.** `~/.audio-archive` isn't on this Mac, so the schema
  can start clean. If an old `archive.db` turns up, write a one-off importer.
- **Audio.** 16 files from RA-001 to RA-007 are backed up and verified in
  `~/Music/remanence-backup`, with `manifest.tsv` and `SHA256SUMS`. There's no
  off-machine copy yet.
- **Toolchain.** Xcode 27.2 and Swift 6.4, `ffmpeg` and `claude` are installed.
  Still needed: `whisper-cpp` and the base, medium and Silero VAD models.
- **Hardware.** M1 Pro with 16 GB. The Scarlett model is still unknown.

## Architecture

```
Remanence.app         SwiftUI screens, menu bar, windows
RemanenceCore         Local Swift package: everything testable without UI
  Store               GRDB schema, queries, migrations
  Library             Import, hashing, file layout, delete
  Jobs                Persistent queue, retries, crash recovery
  Tools               Subprocess runner; ffmpeg, whisper, claude wrappers
  Audio               Playback, waveform peaks, capture, meter maths
  Push                Site API client
```

### Data model

```
tape     uuid, catalog number, title, medium, machine, speed, context, approved_at, pushed_at
source   tape_id, side, master path, sha256, duration, rate, channels, trim start/end, peaks path
marker   source_id, time
track    source_id, start/end derived from markers and trim, name, summary
segment  source_id, start, end, text (FTS5 over segments)
job      source or track, type, status, attempt, model, error, timestamps
machine  name, medium, speeds, input, knob note
```

- A `source` is one continuous recording. An imported tape with five files has
  five sources, each with one track.
- Tracks are spans of a source, so moving a marker never touches audio.
- Indexing segments individually is what lets search open at the exact moment.
- Markers also get an `origin` column (`manual` for now), so suggestions can be
  added later without reworking the model.

## Phases

Each phase ends with something usable.

### 0. Foundations

Xcode project, `RemanenceCore` package, schema and tests. A setup screen checks
for `whisper-cli`, the models, `ffmpeg` and `claude`, and offers to download
missing models.

**Done when:** the app launches, passes its setup checks and has a test suite
running from Xcode.

### 1. Library

Import the backup, using `manifest.tsv` for catalog numbers and hashes, and pair
masters with prep files. Build the shelf, tape detail panel, playback, and delete
(moved to Trash, removing all related rows). Refuse duplicate imports by SHA-256.

**Done when:** all seven catalog entries are on the shelf and play.

### 2. Pipeline

Persistent job queue, subprocess runner, prep, transcribe and summarize, plus the
menu bar item, login item and drag-and-drop import.

**Done when:** dropping a file on the window ends with a summary, surviving a
force-quit partway through.

### 3. Read-along and search

Follow-along transcript, in-place segment editing, context notes, "Looks good",
"Try a better transcript" with comparison, and search that plays the moment.

**Done when:** a search for a phrase opens the tape playing at that phrase.

### 4. Review

Whole-tape and zoomed waveforms, scrubbing, markers, hear the join, snap to quiet,
trim, keyboard shortcuts, and the track list. Waveform peaks are cached to disk.

**Done when:** a 79-minute master like RA-005 scrubs instantly and can be split
accurately by keyboard alone.

### 5. Recording (needs the Scarlett)

Machine profiles, level check, VU meter with peak light, crash-safe capture to a
format without WAV's 4 GB limit, end-of-tape prompt, side flips, channel check,
disk and device warnings, sound and notification alerts. Pipeline work pauses
during capture.

**First step:** record one full raw cassette side to calibrate the meter
thresholds and end-of-tape signal on real hardware.

**Done when:** a full tape is recorded with no dropouts, and a force-quit mid-tape
loses at most the last moments.

### 6. Push to the site (changes both repos)

Site changes (see below), then the app's push screen. Track files are cut from
masters at push time, and uploads show progress and resume after failure.

**Done when:** pushing twice uploads nothing the second time, and existing entries
are untouched.

### 7. Retire the old code

Once the app does everything you use, remove `cmd/`, `internal/`, `web/`,
`scripts/`, `go.mod` and the Makefile, and rewrite the README. `docs/DESIGN.md`
becomes a historical record. Git keeps the old code.

## Site API changes

From `remanence-archive/src/app/api/sync/route.ts`:

1. **Records are matched on `metadata.audio_archive_id`.** A new database restarts
   at 1, so it could match and overwrite a live entry. Don't run the old
   `archive sync`. Use a UUID (`tape_uuid`) for new records.
2. **An update replaces everything.** `images` defaults to empty, and title,
   description and tracks are overwritten, so a re-sync can wipe photos and admin
   edits. New pushes shouldn't update existing records. Any update should be an
   explicit action that sends only the fields being changed.
3. **The "reserve" step doesn't reserve.** `GET /api/sync` only calculates the next
   number. It also sorts catalog numbers as text, which breaks past RA-999. The
   insert should assign the number.
4. **No existence check.** Add `POST /api/sync/check`, taking SHA-256 hashes and
   returning which ones exist, and store each file's hash on its track.
5. **Re-uploads leave orphans.** Keys include a timestamp, so each upload creates
   a new object. The existence check prevents this in normal use.
6. **Existing files need hashes.** Backfill RA-001 to RA-007 from `manifest.tsv`
   with a one-time script, so the first push doesn't re-upload them.

The site's secrets aren't in the local clone, so this phase needs access to its
environment variables. Deploying and changing the production database each need
your confirmation at the time.

## Lessons to carry over

| Lesson | Source | In the new app |
|---|---|---|
| Background QoS makes Whisper about 200× slower | Worker plist | Run transcription at user-initiated QoS, and test it with the window closed |
| Parallel Whisper runs were OOM-killed | Apr 15 batch | One transcribe at a time |
| Whisper hallucinates on non-speech audio | `summarize` | Always pass `--vad --vad-model`; keep the speech-density hint |
| Missing VAD model aborts `whisper-cli` | `whispercpp.go` | Check for it in setup and before each run |
| Leaked child processes hang pipes | `subprocess.go` | Own process group, kill the group on cancel, bound the wait after exit; port the regression test |
| Shutdown shouldn't use up retries | `manager.go` | Cancelled jobs go back to pending with no attempt counted |
| Downstream jobs wasted retries | `jobs.go` | Dependency-gated claims, with failures cascading |
| Interrupted jobs stayed "running" | `jobs.go` | Reset running jobs at launch |
| GUI apps don't inherit shell `PATH` | launchd `claude` bug | Absolute tool paths, verified in setup |
| FTS needs update and delete triggers | `migrations.go` | Install all three from the first migration |
| Larger model made a phone call worse | Apr 16 benchmark | Base by default on microcassette, larger on reels; always compare before replacing |
| Dedup missed a duplicate file | Apr 16 cleanup | Identify files by content hash only |

Port as-is: the prep filter chain (`internal/audio/prep.go`), summary prompts
(`internal/summarize/prompts.go`), the recording types (`types.go`) and summary
normalization.

## Later

Filtering and sorting the shelf, a label on each shelf saying what it holds, a
list view showing everything in one place with an icon for each tape's format,
automatic track suggestions, chapters from transcripts, box photos with
Continuity Camera, hum and tape-speed checks, and dark mode tuning. The split test showed silence alone needs a raw transfer to tune against,
and sorting by gap length is the likely starting point.

## Open items

- Scarlett model, and which sample rate to record at (24-bit/96 kHz assumed)
- Whether unsynced recordings exist on an older Mac or in R2 drafts
- Copying `~/Music/remanence-backup` off this Mac
- RA-006's "24-bit · 96 kHz" label, since its only file is 16 kHz, 16-bit mono
