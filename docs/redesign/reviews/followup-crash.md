I'll review the staged crash-fix against the findings notes and the redesign constraints, without changing anything.

The fix notes claim the cancelled tool check no longer reads a running process. I'll inspect the staged diff and the surrounding setup code against that claim.

The crash fix is correct and stays inside the cancelled setup check. `runTool` now waits until the tool has actually exited, stops it on cancellation, and only then reads the exit state. A cancelled `refresh()` drops that result instead of storing it as a failure.

`ExitSignal` resumes exactly once, so a cancelled task no longer ends the wait early. `terminate()` is a no-op if the process has already finished, and `Task.checkCancellation()` throws `CancellationError` before the timeout check, so a cancel is not reported as a timeout. The success and timeout paths are unchanged. `cancellingStopsTheToolAndWaitsForIt` covers the crash: the call throws `CancellationError` within 10 seconds and the process is gone.

`refresh()` returns before saving the cancelled check, setting `hasChecked`, or starting the pipeline. An incomplete pass does not mark the catalog checked. A later refresh still behaves as before.

`runSubprocess` already waits with `waitpid` and kills the process group on cancel before it returns a status. The `Process()` in `scripts/dev/app.swift` is a one-shot `pgrep` outside the app. Both skips are sound.

The shared runner also covers `ffmpeg` and `ffprobe`. A cancel throws before a partial encode is moved into place, `PushModel` already treats `CancellationError` as a clean cancel, and a recording is only deleted as header-only before probing. Masters, push drafts, the site clock, and the live site are untouched. No SwiftUI layout code changed. The diff is `Setup.swift`, `AppModel.swift`, and `SetupTests.swift`.

The reported run is build 0 and 449 tests. This review did not re-run them.

No findings.

VERDICT: PASS
