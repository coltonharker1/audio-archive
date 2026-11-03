# Native macOS app: build plan

Replaces the Go CLI, launchd daemons and Next.js review app with one Swift app.
Written 2026-11-02. Mockups: https://claude.ai/artifact/Vec7wX1cEPYiuFKDuKfzE9

## Current status

**Last updated 2026-11-03.** Branch `native-app`, not pushed. See
[CLAUDE.md](../CLAUDE.md) for commands and rules.

| Phase | State |
|---|---|
| 0. Foundations | Done, committed |
| 1. Library | Done, committed |
| 2. Pipeline | Done, committed |
| 3. Read-along and search | Done, committed |
| 4. Review | Done, committed (`997a3cd`) |
| **5. Recording** | **Committed and tested live on the MacBook mic. Needs the Scarlett to finish.** |
| 6. Push to the site | Not started |
| 7. Retire the old code | Not started |

### Next steps

**Phase 5 so far.** The live test on the MacBook mic passed on 2026-11-03: a stable meter, level check, a 96 kHz 24-bit recording with real sound, a
marker in the right place, Side B on the same tape, and recovery after `pkill -9`. All
211 tests pass. The test tape is removed, and the temporary debug hook is gone.

Live testing also replaced `AVAudioEngine` in `AudioCapture` with an input-only HAL
audio unit (see Lessons). No automated test covers that, because it needs hardware.

**1. Calibrate with real hardware.** Needs the user at their machines with the
Scarlett. Record one full raw cassette side with some known track breaks, note the
Scarlett model, then tune the meter thresholds (`LevelAdvice`) and end-of-tape
detection (`TapeEndDetector`). Both are provisional. Also check these, none of which
the MacBook mic could test:

- Capture from an input that isn't the system default
- Stereo, and 96 kHz on the Scarlett itself
- Unplugging the interface mid-recording
- No dropouts over a full tape. The audio thread now allocates a small copy of each
  block, so if dropouts appear, replace that with preallocated buffers.
- The transcription queue resuming afterward

Phase 5 is only done when a full tape records with no dropouts.

**2. Phase 6, push to the site.** Needs access to the site's environment variables,
and confirmation before deploying or changing its database.

### Not yet tried in the running app

Most of this works in tests, or was driven by keyboard or hook, because real clicks
don't reach a window on another Space. The user should try these, or test them when
the window can be on screen.

- **Shelf:** Import Backup button, Move to Trash, real drag-and-drop onto the window
  (only the Dock route was tested), and the Play button after the panel changes.
- **Menu bar:** clicking the item. Leave Open at Login off until the app is in
  Applications, because it would point at the build folder.
- **Read-along:** clicking a line, the pencil, Follow Along, Write a Summary, Looks
  Good, and the "Listening… 42%" display, which hasn't been seen with a number.
- **Review:** dragging markers, drag scrubbing, on-screen buttons, pinch and swipe,
  J K L, O, zoom keys, ⌘⇧Z, and typing a track name. Whether scrubbing sounds right
  needs a listen.
- **Recording:** every on-screen button, Large Meter, alert sounds, notifications,
  unplugging the interface, and the low-disk warning.
- **Dark mode:** the app is forced to light mode until it gets its own design.

### Known limits

- Tracks from markers have no summary until **Write a Summary** is clicked.
- ⌘Z works on the review screen, but Undo stays greyed out in the Edit menu.
- The shelf panel shows the track count but lists whole recordings. Review shows
  individual tracks.
- A new tape waits behind anything already queued.
- Closing the lid pauses processing, so keep it open for long batches.
- A crash or force-quit while the record screen is open leaves the input at 96 kHz,
  because the old rate is only restored on a normal stop. Recording still works, and
  Audio MIDI Setup can put it back.
- `web/` and the Go code still exist, and `README.md` describes the old app until
  Phase 7.

### Library state

Seven catalog tapes (7.9 hours), all transcribed, 2,669 segments, and waveforms
cached. No markers, edits or test tapes. Site tapes have no summaries, on purpose,
because they have the site's descriptions. Summaries run only when requested.

### Findings to raise with the user

- **Backup:** `~/Music/remanence-backup` still has no off-machine copy, and the
  library's clones aren't a second copy.
- **RA-006:** its only file is 16 kHz, 16-bit mono, while its page says "24-bit ·
  96 kHz". It's worth re-recording if the tape is still around.
- **RA-001 tracks 4 and 5:** different audio with identical lengths, possibly two
  channels or passes of one session. Worth a listen.
- **Masters:** they look normalized (several peak at exactly -0.1 dB), and all nine
  stereo masters are really mono.
- **Check R2:** the Cloudflare dashboard may hold files beyond the 16 backed up, and
  the site admin may hold drafts. The old notes mention 9 accordion tracks, but
  RA-001 has 5.

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
- **Toolchain.** Xcode 27.2 and Swift 6.4, with `ffmpeg`, `claude`, `whisper-cpp`,
  `xcodegen` and the base, medium and Silero VAD models all installed.
- **Hardware.** M1 Pro with 16 GB. The user has a Focusrite Scarlett (model not yet
  known), cassette and microcassette machines, a 7" reel and a 5" reel.

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
`scripts/launchd/`, `go.mod`, `go.sum` and the Makefile, and rewrite the README. `docs/DESIGN.md`
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
| A closed lid used up a job's retries | Nov 2 summary test | Time limits ignore sleep, nothing starts until fully awake, and failures across a sleep don't count |
| Claude Code needs `USER` to find its login, and exits 0 when signed out | Nov 2 testing | Pass `USER`, check `is_error`, and check sign-in during setup |
| Real gaps are spiky at 10 ms resolution | Nov 2 review | Smooth to about 100 ms, bridge blips under 0.3 s, and measure quiet from each tape's own floor |
| Two identical recordings collided on the duplicate rule | Nov 2 recording tests | A recording always saves, with a repeat's hash marked to stay unique |
| The engine could stop while the app thought it was listening | Nov 3 mic test | Restart on input changes while idle, verify `isRunning`, and warn if no buffers arrive |
| Reusing one audio engine crashed on switching devices | Nov 3 mic test | Capture no longer uses `AVAudioEngine`. A new audio unit per start, with the format read from the hardware side |
| `AVAudioEngine` stops itself about 30 ms after starting when pointed at the input-only built-in mic | Nov 3 live test | Use an input-only HAL unit, with output disabled |
| `AVAudioEngine` keeps the first rate it sees for the life of the app, so a 96 kHz device was saved at 48 kHz, even with a new engine | Nov 3 live test | The HAL unit reads the real rate. Check the saved file's rate, not just the device's |
| Virtual inputs and in-use devices | Nov 3 mic test | Real hardware first, and never change the rate of a device another app is using |

Port as-is: the prep filter chain (`internal/audio/prep.go`), summary prompts
(`internal/summarize/prompts.go`), the recording types (`types.go`) and summary
normalization.

## Later

Filtering and sorting, a label on each format's shelf saying what it holds, and
a list view showing everything in one place with an icon for each tape's format.
Sorting applies within each shelf in shelf view and across everything in list
view, using one shared control. Also:
automatic track suggestions, chapters from transcripts, box photos with
Continuity Camera, hum and tape-speed checks, and dark mode tuning. The split test showed silence alone needs a raw transfer to tune against,
and sorting by gap length is the likely starting point.

## Open items

- Scarlett model, and confirming the 24-bit/96 kHz capture the app aims for
- Whether unsynced recordings exist on an older Mac or in R2 drafts
- Copying `~/Music/remanence-backup` off this Mac
- RA-006's "24-bit · 96 kHz" label, since its only file is 16 kHz, 16-bit mono
- The transcript comparison keeps edits only if you keep the current transcript.
  Using the new one replaces corrected lines, after a warning.
