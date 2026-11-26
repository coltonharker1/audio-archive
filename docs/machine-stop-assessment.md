# Assessment: `MachineStopDetector` (machine-stop branch)

Assessed 2026-11-25 by reading the doc, the uncommitted code, the tests and the `redesign` branch. Nothing was built, run or written, so every claim about behaviour below comes from tracing the code and has not been observed.

**In short:** adopt it, with conditions. The idea is sound and the change cannot harm a recording. The doc overstates one safeguard, the thresholds have thin margins, and it has never run during a real recording.

## 1. What it proposes, in plain terms

While recording, Remanence asks "Has the tape finished?" so a recording doesn't run on after the reel is spent. The old `TapeEndDetector` asked whenever the input went quiet. Reels have long gaps, so it mostly asked while the tape was still playing.

The proposal changes the question from "is it quiet?" to "has the machine stopped?". Tape moving past the head adds a little midrange noise, even when blank. A stopped machine only passes its electronics' noise. Colton's two reference recordings (RA-014 side B, blank tape running; RA-015, Teac on but not running) show blank tape 4–8 dB louder between 500 Hz and 2 kHz.

The detector works like this:

- **Band:** it measures the 500 Hz–2 kHz band once a second.
- **Floor:** it remembers the quietest second heard, including the last 30 seconds of listening before Record.
- **Ask:** it asks when the band has sat within 2.5 dB of that floor for 8 seconds, provided the tape while running was at least 3 dB above it.
- **Unknown floor:** if the quiet stretch itself set the floor, it waits 60 seconds instead of 8.
- **Only a question:** it never stops the recording.

## 2. Technical soundness

### What holds up

- **The band is well motivated.** Two independent passes agree that treble is useless and the midrange separates. The first 1.2 s of RA-014 B matching RA-015 is a good check that the comparison is fair.
- **The measure is self-calibrating.** It compares the input with its own floor, so it doesn't depend on absolute level.
- **The filters are correct.** The biquads match the Audio EQ Cookbook with Q = 1/√2, and the low-pass corner is clamped for low sample rates.
- **Slap rejection is sensible.** Each second is the 5th-lowest of ten 100 ms readings, so up to five loud tenths are ignored.
- **The real-master evidence is useful.** Eight Teac sides were flagged 2–10 s after the stop, and four overruns would have been caught (RA-009 B, RA-010 A, RA-011, RA-012 A).

### Main finding: the "running level" check is weaker than the doc says

The doc says the 3 dB condition "is what makes gaps harmless", because the 20th percentile reflects the tape's gaps. That only holds when at least a fifth of the tape's seconds are at gap level. On a dense tape the 20th percentile is program level (`runningLevel`, `MachineStopDetector.swift:197`), so the check always passes. The only real test left is "within 2.5 dB of the quietest second so far". Two consequences:

- **Second gap on a dense tape, stopped machine never heard.** If Record is pressed with the tape already rolling for 30+ seconds, the first gap sets the floor and is protected by the 60-second rule. The second gap is not: `knownBefore` (line 189) is now true, so it asks after 8 seconds. After Keep Recording it re-arms and asks at every later gap. `aFirstGapOnADenseTapeIsNotAStop` stops before a second gap, so no test covers this.
- **Tape no louder than a stopped machine.** The Limits section says the detector "stays quiet rather than guess". On a dense tape it asks in every gap instead. `aTapeNoQuieterThanAStoppedMachineIsLeftAlone` passes only because 60 of its 80 seconds are stopped-level. The mid-tape questions on the old RA-002 and RA-004 exports are this failure, not a special case.

A first gap longer than 60 seconds with no known floor also asks. That one is by design.

### Thin margins

- **`nearFloor` = 2.5 dB sits in a narrow window.** The stopped machine drifted 1.5–2 dB above its starting floor on RA-012 A. Blank tape read as low as 3 dB above stopped in the first pass. That leaves 0.5–1 dB on each side.
- **The threshold was tuned on the files that validate it.** 2.5 dB was chosen to catch RA-012 A, which is then counted in the results. There is no held-out recording.
- **The floor only ever falls.** One quieter-than-stopped moment (Teac switched off, a knob turned down) in the last 30 s of listening or during recording lowers it for the whole side. The detector then never asks, with no sign that it has gone blind.

### Smaller bugs and fragile logic

| Issue | Where | Effect |
|---|---|---|
| Digital silence never sets the floor but still counts as "at the floor" | line 163 | 8 s of zeros asks "The machine seems to have stopped". The doc implies it is ignored. |
| One second above floor + 3 dB clears the flag | line 186 | A bump withdraws the question; 8 s later it asks again with a fresh sound and notification. |
| Floor creeping down in steps under 2.5 dB doesn't count as "new" | lines 156–162 | A slow fade into the quietest stretch so far gets the 8 s rule, not 60 s. |
| The first ~50 s of a 60-second stretch enter `history` as running tape | lines 171–174 | After a stop found by the 60 s rule, a later stop can be missed until history dilutes below 20%. |
| Channels are averaged | line 96 | In Stereo with tape on one input, a 6 dB difference shrinks to about 4, and 4 dB to about 2.4, under `nearFloor`. |
| A NaN sample poisons the filter state | `Biquad.run` | The detector goes silent until the input restarts. It does not crash. |

### Tests

- **Synthetic only, in ideal conditions.** The unit tests run at 8 kHz, mono, with a comfortable 6 dB separation. Nothing tests 3–4 dB separation or a drifting floor.
- **Block splitting is untested.** The feeder sends blocks exactly one tenth long, so the splitting loop in `add` (lines 92–101) is only exercised by the gated test.
- **One test can't fail.** `onlyTheLastHalfMinuteOfListeningCounts` checks 5 seconds after Record, when nothing can be flagged for about 40.
- **`realMasters` is a measuring tool.** It has no assertions and no listening phase, and its results were checked by hand with scripts that weren't kept.

### Doc versus code

- "No judgment before 30 seconds of recording" is really 30 seconds of *history*, which is about 40 seconds of recording.
- The one-hour history cap (`historyLimit`) isn't mentioned.
- The doc's command for the gated test omits `-c release`, which the test's own comment asks for.
- The doc is dated 2026-11-25; `native-app-plan.md` says the change was made 2026-11-24.
- "All 429 tests pass" is unverified here. The test folder has 456 `@Test` attributes, which may just be how the runner counts.

## 3. Fit with the app architecture and the redesign

- **Wiring is clean.** `AudioCapture.process` feeds the detector on the processing queue, not the audio thread (`AudioCapture.swift:603`), and the snapshot field becomes `machineStopped`. `RecordModel` changes by five lines. `RecordView` is untouched, so the 900 by 692 layouts are unaffected.
- **No conflict with `redesign`.** The merge base is 272e153, and the five later commits (up to b26f37e) touch Review, Edit, waveform and docs files only. `git diff --stat 272e153 redesign` over the six affected files is empty, so a rebase should apply cleanly. There is no reason to wait for the redesign.
- **Behaviour change for the UI.** The old flag latched until answered. The new one can withdraw the question by itself (`RecordModel.swift:489`) and re-alert through `alert`, which is not throttled, so notifications can stack during a bumpy idle tail.
- **Naming is half-renamed.** `dismissTapeEnd()`, `tapeEndQuestion`, `askingIfFinished` and `tapeFinishedConfirmed()` keep the old idea. This is cosmetic.
- **Copy.** The notification says "Has the tape finished?" and the screen says "Tape finished?". The mismatch is older than this change. The new body text is accurate.
- **Target branch.** CLAUDE.md says to commit on `native-app`, but work now lives on `redesign` and `machine-stop`. Colton needs to say where this lands.

## 4. Risks, especially to masters and data

- **Recording cannot stop by itself.** I traced it: `machineStopped` only sets `askingIfFinished` and plays an alert. The only stop path is the "Yes, Stop Recording" button.
- **The audio is untouched.** The detector only reads the buffers, and the payload for the file is built before it runs.
- **No realistic crash path.** Array indexing is guarded at the default settings. A trap would need `minimumHistory` set to 0 or an infinite sample rate.
- **CPU cost is small.** It is two biquads per sample per channel while holding the snapshot lock. Debug builds are slower, and Phase 5's "no dropouts over a full tape" is still open, so watch the dropout count in the trial.
- **The gated test reads the real library.** `realMasters` opens every `.caf` and `.wav` under `masters/` with `AVAudioFile(forReading:)` and prints. It writes nothing and doesn't open `library.sqlite`. It runs only when `REMANENCE_STOP_CHECK` is set. Quit the app first, because a capture in progress would likely make it throw part-way. It was not run in this session.
- **The real cost is missed stops.** A miss wastes time and disk, as today. A false question is a nuisance. Neither loses audio.
- **The old fallback is gone.** A minute of plain hiss used to ask. On a tape the new detector can't judge, nothing asks at all.

## 5. Gaps and open questions

- **Not tried live.** The doc says so. The listening-floor path, real 512/1024-frame blocks at 96 kHz and the withdraw-and-re-ask behaviour have never run on hardware.
- **One machine, one setting.** The app also seeds Cassette and Microcassette machines. Their noise, Dolby and auto-stop behaviour are unmeasured.
- **Starting with the tape already rolling** is unproven on real audio, and is where the main finding bites.
- **The measurements can't be re-run**, because the analysis scripts were throwaway.

Decisions for Colton:

1. Should the question latch until answered, or withdraw itself as now?
2. Should repeat alerts be throttled or replace the earlier notification?
3. Is a simple long-quiet fallback wanted for tapes the detector can't judge?
4. Which branch does this land on?
5. Do RA-014 and RA-015 stay as catalogued tapes or become calibration files?

## 6. Effort and phasing

Done: the detector, the wiring, 12 unit tests, the gated test and both docs.

Remaining, in order:

1. **Rebase onto `redesign` (b26f37e).** Minutes; no overlapping files.
2. **Tighten before the trial** (about half a day):
   - Add failing-first tests for a second gap on a dense tape, 8 seconds of digital silence, misaligned blocks at 96 kHz stereo, and 3.5 dB separation with a +2 dB floor drift.
   - Fix the dense-tape case.
   - Decide digital silence.
   - Correct the doc's Limits section and its "30 seconds" figure.
3. **Full test run and build**, and re-confirm the test count.
4. **Live trial on the Teac**, with Colton's go-ahead. Record one full reel through run-out, do one start with the tape already rolling, pause once mid-tape, and press Keep Recording once. Check the file's rate with `ffprobe` and the dropout count, then remove the test recordings.
5. **Re-run `realMasters`** in release with the app quit, and compare against the doc's table.
6. **Follow-ups:** a cassette deck check, the renames, alert throttling, then commit when asked.

## 7. Recommendation

**Adopt with conditions.** The approach is better than what it replaces, the evidence from real masters is real, and it cannot stop a recording or touch audio.

Conditions before it is called done:

- Fix or explicitly accept the dense-tape behaviour, and correct the doc where it claims gaps are always harmless.
- Add the missing tests in step 2.
- Pass one live reel on the Teac, including run-out.

Until then, describe it in `native-app-plan.md` as "tuned on recorded masters, not yet tried live" and not as settled. It needs no rework, and it doesn't need to wait for the redesign.
