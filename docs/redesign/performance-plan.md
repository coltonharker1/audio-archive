# Performance plan: the spinning wheel

Written 2026-11-25. Investigation and plan only; no code was changed, nothing was built
or launched, and the real library and the site were not touched.

Sources: `~/.remanence-redesign/perf/evidence.md`, the pruned main-thread trees
(`main-*-pruned.txt`), the raw samples (`sample-*.txt`, `nav-main.txt`), the timing log
(`nav-run1.log`), the three `.diag` resource reports, and the code in `Remanence/` and
`RemanenceCore/`. All profiles are from the Debug (`-Onone`) build, sampled every 1 ms,
so one sample is about 1 ms of main-thread time.

## 1. Summary

**The spinning wheel is one bug on the Review tab.** Going back to Review from Edit,
Read Along or Site Post freezes the app for 15 to 100 seconds. The freeze is a single
redraw of the "Whole side" waveform strip that is asked to draw roughly ten million bars
instead of a few hundred. Opening a tape for the first time doesn't do it; coming back
to Review does, every time it was tried (3 of 3).

Everything else that was audited is small by comparison:

- Opening Recording blocks the window for about 0.7 s while the audio input starts.
- In the Debug build the waveform maths is slow enough (25 to 70 ms per redraw of the
  strip) that dragging, zooming and panning on Review and Edit stutter. A Release build
  makes this part disappear.
- The database, setup checks, imports, photo thumbnails and all site calls already run
  off the main thread. A slow or unreachable site shows a spinner; it cannot freeze the
  window. The Keychain read costs about 13 ms once.
- The "disk writes" reports are real work, not a leak: rendering a reversed track for a
  push, and saving recordings. They happen off the main thread and don't cause the wheel.

**The owner's own samples don't show his hang.** In all four
(`main-colton-own-1..4-pruned.txt`) the main thread is idle for every sample (24,479,
24,524, 22,108 and 22,242 samples, all in `mach_msg2_trap`), so he wasn't in a freeze
while they ran. One hint that his instance had hit the same bug earlier: its peak memory
was 291.8 MB against 80.3 MB at sampling time, the kind of spike a huge waveform array
leaves. That is suggestive, not proof.

**One thing is not yet confirmed:** *why* the strip is asked for ten million bars. The
profile proves the size of the work and where it runs. The cause below is the best
reading of the code, and phase 1 starts by confirming it with two log lines before
changing anything. The phase 1 fix is written to work whichever way that turns out.

**Release build:** the freeze would be shorter but would still be a freeze, an estimated
3 to 10 s. The level maths gets about 100 times faster, but the ten million draw calls
go through SwiftUI, which is already optimised. The Debug-only stutter goes away.

## 2. Suspected causes, ranked

### 2.1 Review's whole-side strip draws about ten million bars (the hang)

**Status: confirmed by profile.** Trigger not yet confirmed (see "Why").

Evidence:

- `nav-run1.log` line 11: pressing Review after Site Post returned AX error -25204 and
  the app answered nothing for about 100 s (09:05:19 to 09:06:59). Focused run: Edit to
  Review 61.2 s (the 60 s sample ended first), Read Along to Review 14.8 s. Opening the
  same tape from the Shelf: 2.1 s, with a normal-sized draw.
- `main-review-focused-pruned.txt`: 27,305 of 31,122 main-thread samples are one stack:
  the Review button press, one `ViewGraphRootValueUpdater.render`, one
  `CanvasDisplayList.updateValue`, then `OverviewStrip.body`'s canvas
  (`ReviewView.swift:198`) calling `Waveform.levels` (`Waveform.swift:188`).
- `nav-main.txt`: the same stack, 29,573 samples in `Waveform.levels` and a further
  17,665 in `drawLevels` (`ReviewView.swift:168-177`, called from line 199). About
  47,400 of 74,741 samples in the whole navigation run.
- A healthy call for the same 10-minute tape is in the same files: 26 and 68 samples in
  `levels`, 1 in `drawLevels`. The hung call is over 1,000 times bigger.
- It is one huge call, not many small ones. Inside `levels`, the loop over columns
  (`Collection.map`, 4,937 samples in `Range.formIndex`) costs a quarter of what the
  per-column body costs (20,441). With the normal 140 bins per column the body would be
  hundreds of times the loop. So each column covers about one bin, and there are
  millions of columns. `drawLevels`, whose cost depends only on the column count, grew
  from 1 sample to 17,665. No per-call setup frames (array allocation) appear at all.
- `columns` comes from `size.width / 2` at `ReviewView.swift:197`. So the canvas was
  given a width in the tens of millions of points.

Why (reasoned from code, to be confirmed in phase 1):

- `OverviewStrip` reads `review.duration` itself and falls back to `0.001` when there is
  no review loaded (`ReviewView.swift:191`). Its zoom rectangle is
  `width * zoomSpan / duration` wide (`ReviewView.swift:209`). With `duration = 0.001`
  and a 10 to 90 s zoom, that is 5 to 80 million points, which matches the size of the
  work and explains why each visit hangs for a different time.
- A `ZStack` grows to its largest child, and the canvas in the same `ZStack` takes the
  size it is offered.
- `ReviewModel.observe` clears `review` and `waveform` on every entry
  (`ReviewModel.swift:67-68`). `ReviewModel` outlives the view, so on a return visit the
  strip is first built from the previous visit's ready state, then `review` goes to nil
  under it. On a first visit nothing is on screen when the reset happens, which is why
  first opens are fine.
- Edit has the same shape of code and the same exposure:
  `geometry.size.width * edit.zoomSpan / lane.spanLength` at `EditView.swift:422`, with
  the canvas beside it at `EditView.swift:404-416`. It did not hang in these runs.

User-visible impact: the app is frozen with the wheel for 15 to 100 s (Debug) on every
return to Review. This is the reported problem.

### 2.2 Waveform levels are recomputed on the main thread on every redraw

**Status: confirmed by profile** (cost per call); how often it redraws is from code.

- `Waveform.levels` (`Waveform.swift:182-208`) iterates `ClosedRange` and `map`
  generically. In Debug that costs about 0.5 to 1 µs per bin: 26 to 68 ms per call for a
  10-minute tape (60,000 bins). A 45-minute side would be about 4.5 times that.
- The canvases are rebuilt whenever anything their parent closure reads changes.
  `OverviewStrip`'s closure reads `zoomStart`, `zoomSpan`, markers and the selected
  marker (`ReviewView.swift:189-222`), so panning, zooming, dragging in the strip and
  selecting a marker each recompute the whole-tape levels although they haven't changed.
  `ZoomedWaveform` (`ReviewView.swift:329-337`) and Edit's `LaneWaveform` and `CloseUp`
  (`EditView.swift:404-416`, `640-642`) do the same; in Edit every lane redraws when the
  close-up zooms or pans (`EditView.swift:418-423`).
- `drawLevels` issues one `Path` and one `fill` per bar.

Impact: Debug, visible stutter while dragging or zooming on Review and Edit, worse on
long tapes. Release, well under 1 ms per call; not noticeable.

### 2.3 Opening Recording starts the audio input on the main thread

**Status: confirmed by profile.**

- `main-nav-pruned.txt` lines 805-819: `RecordModel.open` (`RecordModel.swift:104`) to
  `startListening` (`:199`) to `AudioCapture.start`: 657 samples. 299 are
  `preferHighestRate` (`AudioCapture.swift:246-251`, a wait loop of up to 1 s) and 301
  are `prepare` (`AudioCapture.swift:390-393`, `AudioUnitInitialize` and start).
  `makeUnit` can add up to 1 s more (`AudioCapture.swift:324-351`).
- `nav-run1.log` line 62: the window took 0.8 s to answer after pressing Recording.

Impact: 0.7 s pause opening Recording, up to about 2 s worst case, the same in Release
(it is waiting on hardware). Annoying, not the wheel.

### 2.4 Shelf updates redo work on the main thread and redraw everything

**Status: suspected from code only.** The scratch library (8 tapes, none pushed) can't
show it.

- `fetchShelf` (`Library.swift:25-57`) watches tapes, sources, tracks, jobs and markers,
  so every marker move, track rename and job change sends a new shelf.
- `observeShelf` then decodes a site snapshot for every pushed tape on the main thread
  (`AppModel.swift:863`, `ShelfStatus.swift:31`) and replaces `shelf`, which invalidates
  every view that reads `selectedTape` or `selectedItem`, including Review.
- `CatalogView.swift:296` and `:326` and `CollectionView.swift:68` decode snapshots
  again inside `body`.

Impact: unknown. Probably a few ms to tens of ms per database change on the real
library in Debug. Measure before doing anything (phase 5).

### 2.5 Returning to a tab reloads its waveform from disk

**Status: confirmed by profile, small.** `Waveform.init(encoded:)` and its smoothing run
on a background task (`Markers.swift:194-199`): about 180 samples off the main thread
for a 10-minute tape. Nothing is cached, so every return to Review shows "Reading the
waveform…" again, and Edit loads one per source in turn (`EditModel.swift:270-273`).

Impact: a short flash of the loading state on each tab switch, longer on long tapes.

### 2.6 Checked and found not to be causes

| Area | Finding | Evidence |
|---|---|---|
| GRDB on the main actor | None. Every call from the app is `await writer.read/write`. The one synchronous write, `JobQueue.startReadyJobs` (`JobQueue.swift:99`), runs inside the queue's actor. It polls once a second and only writes when it claims a job. | Owner's sample shows `claimNext` on a background thread, 31 samples in 30 s |
| `SetupCatalog.check` and `runTool` | Run off the main thread. `refresh` fires at launch and each time the window becomes active (`RemanenceApp.swift:204-207`) and launches five tools in turn, including `claude auth status`. Wasteful, not blocking. | `sample-import.txt` shows `SetupCatalog.check` only on worker threads; `main-launch-pruned.txt` has no app frames at 150 samples or more |
| Launch and import | No main-thread stall. | `main-launch-pruned.txt` (5,169 of 5,530 idle), `main-import-pruned.txt` (4,963 of 5,297 idle; 261 in opening the dropped files) |
| Network (`SiteClient`, `PushModel`) | All `async` `URLSession` calls. No semaphores or synchronous waits anywhere in either target. With the default URL slow or down, Site Posts, Catalog and Recording wait up to URLSession's 60 s default in the background, showing a spinner or an old number. | Site Posts against a dead URL answered in 0.1 s (`nav-run1.log` line 57) |
| Keychain | `SecItemCopyMatching` runs on the main thread when `PushModel` is first made (`PushModel.swift:12`) and on each `client()` call (`:261`). | 13 samples (about 13 ms) in `nav-main.txt` |
| Photos | `Thumbnail` decodes off the main thread (`SitePostView.swift:1080-1091`). | Code |
| File scans | Only inside imports and deletes, which run in background tasks. `ReadAlongView.swift:430` does one `fileExists` in `body`; negligible. | Code |
| Disk writes (three `.diag` reports, 2.1 GB each) | 23 Nov 16:46, 2.1 GB in 545 s: `writeReversed` (`TrackAdjustments.swift:128`) from `Pusher.prepare` (`Push.swift:367`), rendering a reversed track for a push. The other two (5.2 h and 3.7 h, 114 and 163 KB/s) are `FileHandle.write`, which only `CaptureFile.swift` uses: recordings being saved. All off the main thread. macOS took no action ("Action taken: none"). | The reports' stacks |
| Hang reports | None exist for Remanence. | `log-hangs.txt`, `log-hangtracer.txt` |

## 3. Fixes, in phases

Each phase builds and tests on its own and is sized for Claude Sonnet. Rules for all of
them, from `CLAUDE.md` and `docs/redesign/plan.md` section 1:

- Behaviour and visuals don't change. Compare screenshots at 900 by 692 before and after.
- Don't edit `Recording.swift`, `CaptureFile.swift`, `AudioCapture.swift`, `Sides.swift`,
  `Markers.swift`, `Appending.swift`, `TrackAdjustments.swift`, `Push.swift`,
  `SiteSync.swift`, `CollectionSync.swift`, `Catalog.swift` or `SiteClient.swift`. No
  database migration.
- Test only with the scratch instance (section 4): scratch library, site pointed at
  `http://127.0.0.1:9`, `open -g`, no system-wide keys or clicks.
- SwiftUI traps: no `.fixedSize(horizontal: false, vertical: true)` outside a
  `ScrollView`; keep reading `player.currentTime` beside `player.preciseTime`.
- Run `swift test --package-path RemanenceCore` and the Xcode test command after each.
- Commit only when asked.

Phases 1 and 2 fix the reported problem. Do them first and re-measure before deciding
whether 3 to 6 are worth doing.

### Phase 1: stop the Review hang

Files: `Remanence/ReviewView.swift`, `Remanence/EditView.swift`,
`RemanenceCore/Sources/RemanenceCore/Waveform.swift`, new
`RemanenceCore/Tests/RemanenceCoreTests/WaveformTests.swift`.

Approach:

1. Confirm the cause first. In a scratch build only, log `size.width`, `columns` and
   `duration` in `OverviewStrip`'s canvas and `review.review == nil` in its
   `GeometryReader` closure. Reproduce Edit to Review once. Expect a width in the
   millions and `duration` of 0.001. Remove the logging. If the numbers say something
   else, stop and report; steps 2 to 4 still apply.
2. `OverviewStrip`: never lay anything out wider than the strip. Clamp the zoom
   rectangle to `min(width, …)`, and take `duration` from `waveform.duration` when the
   review isn't loaded instead of `0.001`. Apply the same clamp to Edit's rectangle at
   `EditView.swift:422`.
3. Cap the column count where it is computed (`ReviewView.swift:197` and `:330`,
   `EditView.swift:406` and `:641`), using one shared constant such as 4,096. No real
   window reaches it, so nothing looks different.
4. In `Waveform.levels`, return at most that many columns whatever is asked, as a
   backstop.

Tests (Core): `levels` asked for 50 million columns returns the capped count and
finishes in under 50 ms; for ordinary inputs the output is unchanged (compare against
values recorded from the current code for a small fixed waveform, both styles, with and
without gain).

Acceptance:

- Scratch instance, 10-minute tape: Shelf, tape, Edit, Review, Read Along, Review, Site
  Post, Review. Every AX press returns in under 300 ms in Debug, none returns -25204.
- A 60 s `sample` over that sequence has under 100 samples in `Waveform.levels` plus
  `drawLevels` for any one press.
- Screenshots of Review and Edit at 900 by 692 match before and after.

Risks: low. The clamp only changes layouts that were already broken. If step 1 shows a
different trigger, the caps still bound the damage but the trigger needs its own fix.

### Phase 2: make the level maths fast and stop recomputing it

Files: `RemanenceCore/Sources/RemanenceCore/Waveform.swift`, new
`RemanenceCore/Sources/RemanenceCore/WaveformLevelsCache.swift`,
`Remanence/ReviewModel.swift`, `Remanence/ReviewView.swift`, `WaveformTests.swift`.

Approach:

1. Rewrite the inside of `levels` with plain `while` loops over
   `withUnsafeBufferPointer`, writing into a preallocated array. Same arithmetic, same
   results. This removes the generic iterators that make it slow in Debug.
2. Add a small cache in Core: a value keyed by start, end, columns, style and gain that
   returns stored levels, holding the last few entries. `ReviewModel` owns one per
   loaded waveform and clears it when the waveform changes. `OverviewStrip` and
   `ZoomedWaveform` ask the cache instead of calling `levels` directly.
3. `drawLevels`: build one `Path` per colour and fill twice, instead of one fill per bar.

Tests (Core): new `levels` equals the old implementation (kept in the test file as a
reference) over randomised waveforms, ranges, column counts, both styles and gains;
cache returns identical arrays, hits on a repeated key, misses after the waveform
changes, and stays within its size limit.

Acceptance: in Debug, `levels` for a 60,000-bin waveform and 430 columns takes under
2 ms (timed in a Core test with a generous bound). Dragging in the whole-side strip for
5 s under `sample` shows under 5% of main-thread samples in `levels` and `drawLevels`.
Screenshots unchanged.

Risks: rounding. `Int()` truncation and the `0.02` floor must be copied exactly; the
equality test catches drift. One fill per colour must not change edge pixels; compare
screenshots at 2x and fall back to per-bar fills if they differ.

### Phase 3: redraw waveforms only when they change

Files: `Remanence/ReviewView.swift`, `Remanence/EditView.swift`.

Approach: move each canvas into its own small view whose inputs are plain values
(waveform identity, time range, trims, gain, reversed) and mark it `.equatable()`. The
zoom rectangle, markers and playhead stay as overlays beside it. Do Review first, then
Edit's `LaneWaveform` and `CloseUp`, as two separate changes.

Tests: no Core surface. Check by profile.

Acceptance: panning the Review close-up, and zooming the Edit close-up with eight
lanes, for 5 s each under `sample`: `OverviewStrip`'s canvas and the unselected lanes'
canvases are not called at all (0 samples in their closures). Screenshots unchanged.

Risks: a missed input leaves a stale waveform on screen. List every value each canvas
closure captures today and carry all of them. Compare waveforms by an identity (the
peaks path) rather than by comparing the arrays.

### Phase 4: keep decoded waveforms between tab switches

Files: new `RemanenceCore/Sources/RemanenceCore/WaveformStore.swift` and tests,
`Remanence/ReviewModel.swift`, `Remanence/EditModel.swift`. `Markers.swift` is not
edited; `loadWaveform` stays and the store calls the same decoding.

Approach: an actor holding the last four decoded waveforms, keyed by peaks path plus
file size and modification date, so a regenerated peaks file is never served stale.
`ReviewModel` and `EditModel` ask it instead of `library.loadWaveform`.

Tests (Core): same instance returned on a second request; a rewritten file is re-read;
the fifth entry evicts the oldest; a missing file throws as today.

Acceptance: second and later visits to Review on the same tape spend 0 samples in
`Waveform.init(encoded:)`.

Risks: memory, about 2 bytes per bin: 540 KB for a 45-minute side, so four entries are
small. Open question for the owner: `ReviewModel.observe` still clears and reloads on
each entry, which is what shows "Reading the waveform…" briefly. Keeping the previous
state when the same recording is reopened would remove that flash, but it is a visible
change, so it is left out unless the owner asks for it.

### Phase 5: measure shelf updates on the real library, then decide

Files: none until measured. Likely `Remanence/AppModel.swift`,
`Remanence/CatalogView.swift`, `Remanence/CollectionView.swift`.

Approach: the owner (or an agent, with his go-ahead) runs
`sample <pid> 30 1 -file …` on his own running instance while he adds and drags markers
and a transcription job runs. This only reads the process. If `AppModel.observeShelf`,
`ShelfStatus.init` or `SiteSnapshot.decode` together exceed about 30 samples per shelf
update, then: build the status dictionary off the main actor before assigning; skip the
assignment when the new shelf equals the old; and have Catalog and Collection read the
precomputed status instead of decoding in `body`.

Tests (Core): `ShelfStatusTests` already covers the mapping; add a test for any new
batch function.

Acceptance: under the same use, no shelf update costs more than 16 ms on the main thread.

Risks: skipping an assignment needs `ShelfTape` equality to cover every field the
screens show; if it doesn't, don't skip.

### Phase 6: Recording opens without the pause (needs the owner's go-ahead)

Files: `Remanence/RecordModel.swift` only. `AudioCapture.swift` must not be edited.

Approach: call `capture.start(device:mode:)` from a background task and apply the result
on the main actor, keeping the existing checks (`listeningTo`, `isListening`,
`inputProblem`). First confirm `AudioCapture` is safe to start and stop from a
non-main thread (it guards its state with a lock; check `stopUnit` and the callbacks).
If that can't be shown from the code, stop and report rather than change it.

Tests: existing `RecordingTests`. Manual check on the scratch instance with real
hardware, following the microphone rules in `CLAUDE.md` (say so first, check
`scripts/dev/micuse.swift`, keep it short, quit normally so the sample rate is restored).

Acceptance: pressing Recording returns in under 100 ms; the meter is live within 1 s;
`ffprobe` on a short test recording shows the device's rate; the recording saves.

Risks: this is the capture path, where a mistake costs a tape. A start racing a stop,
or two starts overlapping when the machine is switched quickly, must be ruled out. The
gain is 0.7 s once per session, so skipping this phase is a reasonable choice.

### Not planned

- **Setup re-checks on every activation**: off the main thread, so no wheel. Could be
  skipped when everything was ready within the last minute; low value.
- **Keychain read**: 13 ms, once.
- **Site timeouts**: no main-thread wait exists. Shortening the 60 s wait for the two
  background lookups would change when an error appears, so it is the owner's call.
- **Disk writes**: expected output of pushes and recordings.

## 4. How to re-measure

Use the scratch-instance method in `evidence.md`. Never profile by driving the owner's
own window.

1. Build Debug as usual. Copy `.build/xcode/Build/Products/Debug/Remanence.app` to
   `~/.remanence-redesign/perf/RemanenceScratch.app`, rename the executable to
   `RemanenceScratch`, and re-sign with the same Apple Development identity.
2. Launch it in the background with `open -g`, passing
   `-siteURL http://127.0.0.1:9 -libraryPath $TMPDIR/remanence-scratch`. Check
   `lsappinfo front` first. Seed the library with the generated WAVs listed in
   `evidence.md` (10:00 down to 2:00) and three collections. For phase 2 and 4 add one
   45-minute file to see long-tape cost.
3. Drive it with Accessibility actions aimed at its pid, never system-wide input:
   `AXPID=<pid> ~/.remanence-redesign/perf/nav.sh <label>` presses each screen and
   writes round-trip times to `nav-<label>.log`. An AX call waits for the main thread,
   so its time is the responsiveness; -25204 means the main thread was busy.
4. While it runs, `sample <pid> 60 1 -file sample-<label>.txt`. Read the main-thread
   tree for subtrees that are not `mach_msg2_trap`. One sample is about 1 ms.
5. Compare against the baseline: Edit to Review 61.2 s, Read Along to Review 14.8 s,
   Site Post to Review about 100 s, Recording 0.8 s, others 0.1 to 0.3 s. Targets: every
   press under 300 ms in Debug (100 ms once phase 2 is in), no -25204, and no single
   action with more than 100 main-thread samples outside idle.
6. Repeat once with a Release build (`-configuration Release`) to check the estimate
   that the stutter in 2.2 disappears and to confirm phase 1 holds there too.
7. Quit the scratch instance normally and delete `$TMPDIR/remanence-scratch`.

To catch the owner's own hang: next time the wheel appears, run
`sample Remanence 10 1 -file ~/.remanence-redesign/perf/sample-colton-hang.txt` from
Terminal while it is still spinning. If the top of the main thread is
`OverviewStrip.body` and `Waveform.levels`, it is cause 2.1.
