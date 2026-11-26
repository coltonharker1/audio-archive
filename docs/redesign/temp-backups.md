# Temp folder leak (`remanence-backup-*` and friends)

Investigated 2026-11-25, read-only. Nothing was changed, deleted or run. Evidence:
`~/.remanence-redesign/tmpinv/evidence.md`, plus the checks noted below.

## Summary

- The unit tests leave about 35,600 folders and 18 GB in `$TMPDIR`
  (`/var/folders/gf/…/T/`). Each test makes its own scratch library and never
  removes it. One test run adds roughly 110 MB.
- `remanence-backup-*` (7,830 folders, 2 GB) comes from `BackupFixture` in the
  tests. It is not a backup of anything. The biggest group is `remanence-push-*`
  (10.8 GB), also from tests.
- The app itself cleans up after every job, but only if it exits normally. A
  killed app leaves `remanence-job-*` folders behind (30 today, under 200 KB
  total). These can hold transcript text. The 30 present now hold none.
- No folder looks like the only copy of real data. All of it is test output or
  scratch-library output.
- Fix: one small test helper that puts every test folder under
  `$TMPDIR/remanence-tests/<run>/`, removes it when the run ends, and clears
  dead runs at the start of the next. Plus a sweep of stale job folders when the
  app starts.
- Cleanup: move the test folders to a dated folder in the Trash, check, then
  empty. Commands are below and have not been run.

## What creates them

Every `remanence-*` name in `$TMPDIR` ends in a UUID. The counts are from the
evidence file and were re-counted today.

Tests (`RemanenceCore/Tests/RemanenceCoreTests/`):

| Prefix | Created in | Count | Size |
|---|---|---|---|
| `remanence-push-` | `PushTests.swift:256` | 5,492 | 10,771 MB |
| `remanence-backup-` | `BackupFixture.swift:18` | 7,830 | 1,981 MB |
| `remanence-sync-` | `SiteSyncTests.swift:14` | 1,742 | 1,219 MB |
| `tape-scrub-*.caf` (files) | `TapeScrubTests.swift:11` | 472 | 867 MB |
| `remanence-import-` | `SiteImportTests.swift:13` | 756 | 497 MB |
| `remanence-transcripts-` | `TranscriptTests.swift:34` | 2,983 | 489 MB |
| `remanence-markers-` | `ReviewTests.swift:149` | 2,466 | 413 MB |
| `remanence-post-` | `SitePostTests.swift:14` | 1,904 | 376 MB |
| `remanence-jobs-` | `JobStoreTests.swift:11` | 1,944 | 289 MB |
| `remanence-collections-` | `CollectionsTests.swift:14` | 1,305 | 277 MB |
| `remanence-tests-` | `AppDatabaseTests.swift:10`, `:149` | 1,760 | 242 MB |
| `remanence-queue-` | `JobStoreTests.swift:270` | 1,275 | 213 MB |
| `remanence-sides-` | `SidesTests.swift:11` | 875 | 186 MB |
| `remanence-catalog-` | `CatalogTests.swift:10` | 785 | 163 MB |
| `remanence-capture-` | `RecordingTests.swift:12` | 1,050 | 162 MB |
| `remanence-sub-` | `SubprocessTests.swift:10` | 1,624 | 8 MB |
| `remanence-setup-` | `SetupTests.swift:17` | 1,797 | 5 MB |
| `remanence-real-` | `RealBackupTests.swift:67` | 6 | empty |

`BackupFixture()` is created by seven suites: `BackupImporterTests`,
`LibraryTests`, `PipelineJobTests`, `DropImporterTests`, `CaptureLifecycleTests`,
`WaveformJobTests` and `CandidatePipelineTests`. That is about 49 folders per run,
which matches the clusters of 49 in the evidence.

The `tape-scrub-*.caf` files are not in the evidence file. They add 867 MB.

Tests that do clean up: `remanence-player-*.wav`, `wave-*.raw`, `progress-*.txt`
and `stub-*.flac` all have a `defer` that removes the file. None are left over.

App code (`RemanenceCore/Sources/RemanenceCore/`):

| Prefix | Created in | Removed? | Left over |
|---|---|---|---|
| `remanence-job-` | `Pipeline.swift:298` `makeWorkFolder` | `defer` at every caller | 30 |
| `remanence-tool-` | `Setup.swift:165` | `defer` | 0 |
| `remanence-download-` | `ModelDownloader.swift:91` | `defer` at line 44, and on error at 104 | 0 |
| `remanence-<UUID>-<name>` | `SiteSync.swift:395` | `defer` | 0 |

The app is not sandboxed (`project.yml:50`), so it shares `$TMPDIR` with the tests.

## Why they stay

Tests:

- The suites are Swift Testing structs. Each test gets a new instance, `init()`
  makes the folder, and a struct has no `deinit` or `tearDown` to remove it.
- `BackupFixture` is also a struct. It has no remove method and does not even
  keep its root folder, only `backup/` and the library paths inside it.
- The 20 `removeItem` calls in the tests are either part of what is being tested
  (deleting a tape, removing a side) or cover single loose files. None removes a
  suite's root folder.
- macOS does not clear `/var/folders/…/T` on a schedule you can rely on. Folders
  from Nov 2 are still there.

App job folders:

- All four `makeWorkFolder` callers (`transcribe` line 122, `drawWaveform` 185,
  `summarize` 216, `runChecked` 334) have a matching
  `defer { try? FileManager.default.removeItem(at: work) }`. There is no caller
  without one. Errors, timeouts and cancellation all run it. A normal quit also
  runs it, because `applicationShouldTerminate` waits for `JobQueue.stop()`,
  which cancels the jobs and waits for them.
- A `defer` does not run when the process is killed (`kill`, force quit, crash,
  or Xcode replacing a running build). The tool it started keeps going on its own
  and finishes writing into the folder. That is what the leftovers show:
  `stdout.json` is stamped 6 to 10 seconds after `prompt.txt`, and the FFmpeg
  logs run to completion.
- On the next launch `JobQueue.start()` stops orphaned tools and requeues their
  jobs, but nothing removes the orphaned folders.
- Each job makes two folders, one in the job function and one in `runChecked`.
  That is why the leftovers come in pairs. It is harmless.

What a job folder can hold:

- `summarize`: `prompt.txt`, which includes the track's full transcript, and
  `stdout.json`, the summary.
- `transcribe`: `out.json`, the full Whisper transcript, and `stderr.txt`.
- `drawWaveform`: `audio.raw`, the tape decoded to low-rate mono.

So a killed app can leave transcript text and decoded audio in `$TMPDIR`. This is
a privacy and tidiness problem, not a data-loss one: the transcript is already in
`library.sqlite` and the audio is the master.

## Is any of it real data

No folder appears to be the only copy of anything.

Test folders:

- Only test code writes these names. The app's backup import reads from a folder
  the user picks and writes into the library, never into `$TMPDIR`.
- The layout is the fixture's: `backup/manifest.tsv`, `library/`, `support/`,
  one-second 8 kHz tone WAVs, fake `whisper`, `ffmpeg` and `claude` scripts.
- From the evidence: 25 unique audio and image hashes across the backup folders,
  and none matches any of the 87 files in the real library.
- Checked today: no file over 20 MB exists in any `remanence-*` folder, down to
  four levels. A real master is far larger.
- The folders arrive in bursts that match test runs. 737 were modified in the
  hour before this check, from the 19:27 to 19:41 runs.
- `remanence-real-*` comes from `RealBackupTests`, which only runs with
  `REMANENCE_BACKUP` set. It would hold a copy of the real backup, not an
  original. All six are empty.
- The hash comparison covered only the `remanence-backup-*` folders. The other
  prefixes are judged by their code, names, sizes and the 20 MB check. The
  cleanup plan below repeats the size check before anything is deleted.

Job folders (30):

- 4 are empty, from Nov 7. 26 are from Nov 25, in bursts at 09:04, 10:47 to
  11:18 and 19:38 to 19:42.
- 12 have `prompt.txt`. Every one is for a tone tape: "Tone 440", "Tone 660",
  "Short 440", "Short 660", "Tape 5 Side A" and "Tape 6 Side A". All are 2 to 4
  minutes long with a speech density of about 0 words per minute, so the
  transcript part is empty. These look like scratch-library launches
  (`-libraryPath`) that were killed mid-job.
- The rest hold only `stderr.txt` or `stdout.txt`: FFmpeg progress logs or empty
  files. There is no `out.json` and no `audio.raw`.
- Nothing in a job folder is ever the only copy. A killed job goes back in the
  queue and runs again from the library.

## Proposed fix

Keep it to one test helper and one small app change.

### 1. Tests: one parent folder per run

New file `RemanenceCore/Tests/RemanenceCoreTests/TestFolders.swift`:

```swift
enum TestFolders {
    /// $TMPDIR/remanence-tests/<pid>-<uuid>/, made once per test process.
    static let runRoot: URL = {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "remanence-tests", directoryHint: .isDirectory)
        removeDeadRuns(in: parent)
        let root = parent.appending(path: "\(getpid())-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestFolders.runRoot) }
        return root
    }()

    /// A new, empty folder for one test. Same shape as before, new parent.
    static func make(_ name: String) throws -> URL { … runRoot/"\(name)-\(UUID)" … }

    /// A path for one loose file, such as a .caf or .wav.
    static func file(_ name: String) -> URL { … }

    /// Removes run folders whose process has gone. `kill(pid, 0)` failing with
    /// ESRCH means the process no longer exists.
    private static func removeDeadRuns(in parent: URL) { … }
}
```

Then replace each `FileManager.default.temporaryDirectory.appending(path:
"remanence-x-\(UUID().uuidString)" …)` with `TestFolders.make("x")`, and the loose
files with `TestFolders.file(…)`.

Why this shape:

- Parallel tests still work. Every test still gets its own UUID folder.
- Two test processes at once still work, such as `swift test` beside
  `xcodebuild test`, or a run in the `audio-archive-machine-stop` worktree. Each
  has its own run folder, and the sweep only removes runs whose process is gone.
  A reused pid only delays a removal until the next run.
- A crashed or killed run is cleaned by the next run. The leak is bounded to one
  run, about 110 MB.
- No lifetime risk. Nothing is deleted while a test might still hold an open
  database, because removal happens at process exit.
- A failing test's files stay until the process exits. To look at them
  afterward, an env var such as `REMANENCE_KEEP_TEST_FILES=1` can skip the
  `atexit` removal.

Considered and not recommended as the main fix:

- Making `BackupFixture` a final class with `deinit`, or holding a
  `TemporaryFolder` object that removes itself. Swift may release a local
  `fixture` after its last use, before the test ends (`ReviewTests.swift:337`,
  `TranscriptTests.swift:353`), and delete a library that an open database is
  still using. It would also need changes in every suite, not just the fixture.
- A Swift Testing scope trait (`TestScoping`). It is correct but touches every
  suite's declaration and how each gets its folder.

Either can be added later on top of the run folder if per-test removal is wanted.

Files to change:

- New: `TestFolders.swift`
- `BackupFixture.swift`
- `AppDatabaseTests.swift` (2 places), `CatalogTests.swift`,
  `CollectionsTests.swift`, `JobStoreTests.swift` (2), `PushTests.swift`,
  `RecordingTests.swift`, `ReviewTests.swift`, `SetupTests.swift`,
  `SidesTests.swift`, `SiteImportTests.swift`, `SitePostTests.swift`,
  `SiteSyncTests.swift`, `SubprocessTests.swift`, `TranscriptTests.swift`,
  `RealBackupTests.swift`
- Loose files: `TapeScrubTests.swift:11` (the only one leaking). Optionally also
  `LibraryTests.swift` (3), `ReviewTests.swift` (2), `WaveformTests.swift`,
  `PipelineTests.swift:112` and `PushTests.swift:676`, for consistency. Their
  `defer`s can stay.

Run `xcodegen generate --quiet` after adding the file.

### 2. App: clear stale job folders at start

The `defer`s are already right. The gap is a killed process.

- Add `Pipeline.removeStaleWorkFolders(olderThan:)`. It lists `$TMPDIR` one level
  deep and removes entries named `remanence-job-<UUID>` whose modification date
  is more than 24 hours old.
- Call it from `JobQueue.start()`, next to the existing orphaned-tool recovery,
  or from the app's start-up. Use `try?` throughout so it can never block start.
- The 24-hour age is there because a second copy of the app may be running, for
  example a scratch launch beside the real one, and its live folders must not be
  touched. No job runs anywhere near that long.
- Add one test: an old job folder is removed, a fresh one is kept, and a folder
  with a different prefix is left alone.

Optional and small: `runChecked` could reuse the caller's folder and stop making
a second one per job.

Files: `Pipeline.swift`, `JobQueue.swift` (or `AppModel.swift`),
`PipelineTests.swift`.

### 3. Docs

Add a line to the "Testing the running app" rules in `CLAUDE.md`: quit the app
normally rather than killing it, which also leaves job folders behind. Scratch
libraries belong in one known place.

## Cleanup plan

Not run. The approach is to move first, check, and delete last. The Trash is on
the same volume as `$TMPDIR`, so the moves are instant. Space is only freed when
the Trash is emptied.

Before starting:

```sh
# Nothing should be testing. This should print nothing.
pgrep -lf 'swiftpm-testing-helper|xctest|xcodebuild|swift-test'

# Know what the app is doing. It was running (pid 87696) during this check.
pgrep -lf 'Remanence.app'

cd "$TMPDIR" && pwd      # expect /var/folders/gf/n0wtt1hj7q5cn6c717nsmqnm0000gn/T
```

Step 1. Move the test folders that are more than an hour old:

```sh
Q="$HOME/.Trash/remanence-tmp-2026-11-25"
mkdir -p "$Q"

for p in backup push sync import transcripts markers post collections jobs \
         tests queue sides catalog capture sub setup real; do
  find "$TMPDIR" -maxdepth 1 -type d -name "remanence-$p-*" -mmin +60 \
    -exec mv -n {} "$Q"/ \;
done

find "$TMPDIR" -maxdepth 1 -type f -name 'tape-scrub-*.caf' -mmin +60 \
  -exec mv -n {} "$Q"/ \;
```

What this leaves alone, on purpose:

- Anything modified in the last hour.
- `remanence-job-*`. The pattern `remanence-jobs-*` does not match it, because of
  the `s` before the dash.
- `remanence-download-*`, `remanence-tool-*` and `remanence-<UUID>-<name>`. These
  belong to the app and none exist now.
- `remanence-scratch` or any other name without a listed prefix. None exists now.
- Anything under `~/Music`.

Step 2. Check before deleting:

```sh
ls "$Q" | wc -l                       # about 35,000 to 36,000
du -sh "$Q"                           # about 18 GB
find "$Q" -type f -size +20M          # must print nothing
find "$TMPDIR" -maxdepth 1 -name 'remanence-*' | wc -l    # the recent few hundred, plus 30 job folders
```

For more certainty, repeat the evidence file's hash check over all of `$Q`: hash
every `.wav`, `.caf`, `.flac` and `.jpg` and compare against the real library's
checksum list. Expect no matches. Then open the app and confirm the library looks
right.

Step 3. Delete. Empty the Trash from Finder, or:

```sh
rm -rf "$HOME/.Trash/remanence-tmp-2026-11-25"
```

Step 4. Job folders, separately. Quit the app normally first, or wait a day, so
no live job is touched:

```sh
ls -ldT "$TMPDIR"/remanence-job-*
grep -h '^- Source file' "$TMPDIR"/remanence-job-*/prompt.txt     # expect only tone tapes
mkdir -p "$Q-jobs"
find "$TMPDIR" -maxdepth 1 -type d -name 'remanence-job-*' -mmin +1440 \
  -exec mv -n {} "$Q-jobs"/ \;
```

They total under 200 KB, so there is no hurry. Once the app fix is in, it removes
them by itself.

Step 5. The folders from the last hour of test runs can be moved the same way
later, by repeating step 1. Once the test fix is in, new runs stop adding any.

## Open questions

1. "Tape 5 Side A" and "Tape 6 Side A" appear in four leftover prompts. They are
   2.5 to 4 minutes long with no speech, so they look like scratch tapes. Can you
   confirm they aren't from the real library? It doesn't change the cleanup,
   since the prompts hold no transcript text either way.
2. What killed the app in the middle of jobs on Nov 25, at 09:04, 10:47 to 11:18
   and 19:38 to 19:42? Most likely scratch launches during the redesign work
   being killed or replaced by a rebuild. If a helper script does this, it should
   quit the app normally.
3. Where do scratch libraries (`-libraryPath`) live? `plan.md` says
   `$TMPDIR/remanence-scratch`, but nothing by that name exists now. If they go
   back into `$TMPDIR`, the cleanup patterns above still skip them.
4. Does `atexit` run in both test hosts, `swift test` and `xcodebuild test`? It
   should, and the dead-run sweep covers it if not. Check both once after the
   change: `ls "$TMPDIR/remanence-tests"` should be empty after a run.
5. Should failing tests keep their files by default? The proposal removes them
   at exit unless an env var says otherwise.
6. Is 24 hours the right age for the job-folder sweep? Shorter is possible if two
   copies of the app never run long jobs at once.
7. Do you want the full hash check over the other prefixes before emptying the
   Trash, or is the 20 MB size check enough?
