Reviewer: grok-4.7-build-fast.

The uncommitted fix matches the plan. Bug 1 (a later gap on an unconfirmed floor no longer gets the 8-second rule) and Bug 2 (stopped-looking seconds stay out of the running level) are implemented as specified, including the optional silence and 3-second-withdraw behavior. Recording still never stops itself, the detector only reads buffers, `realMasters` stays gated and read-only, and the docs do not claim a live trial or a re-run of the old master results. The package tests the operator re-ran are taken as given (499 passed). This review did not build or run anything.

1. [minor] `RemanenceCore/Tests/RemanenceCoreTests/RecordingTests.swift:504` — `itStaysStoppedThroughALongIdle` does not hold the question for ten minutes. `feed` returns on the first second once `machineStopped` is already set (`stopOnFlag` defaults to true), so the 600-second call is one second long. A later clear during a long idle would still pass. Pass `stopOnFlag: false` on that call.

2. [minor] `docs/machine-stop-detector.md:245` — Phase 6's scratch-file check was not run. The cold/primed `realMasters` path is implemented and the doc says so, but nothing has exercised the six-times-first-second prime or the "question about 8 s into the last quiet part / cold never asks" acceptance.

3. [minor] `docs/machine-stop-live-trial.md:104` — The band-level command hardcodes `asetnsamples=n=96000` while the sentence above says to set `n` to the file's sample rate. On a 48 kHz take that window is two seconds, not one.

VERDICT: PASS
