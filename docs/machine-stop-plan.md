# Plan: fix pass for `MachineStopDetector`

Written 2026-11-25 on the `machine-stop` branch, after
[machine-stop-assessment.md](machine-stop-assessment.md). It covers the two bugs the
assessment found, the missing tests and the doc corrections.

Revised the same day after a review
([machine-stop-plan-review.md](machine-stop-plan-review.md)). What changed is listed
under "Review changes" at the end.

Nothing here has been built or run. Every "today it does X" below comes from tracing
the code by hand, and every test window (such as "asks at second 7–9") is a
prediction from that tracing.

## Summary

The detector asks "Has the tape finished?" when the 500 Hz–2 kHz band has sat at the
quietest level heard so far (the floor). It has two bugs, and they share a cause: it
treats "the quietest thing so far" as "the machine stopped" too easily.

**Bug 1: it asks during gaps on a busy tape.** If Record is pressed with the tape
already playing, the detector has never heard the stopped machine. The first long gap
becomes the floor, and the 60-second rule protects it. Every later gap at the same
level is then treated as a known floor and asks after 8 seconds
(`knownBefore`, `MachineStopDetector.swift:189`). The 3 dB "running level" check
doesn't help, because on a busy tape the 20th percentile is the program itself.

**Bug 2: stopped seconds leak into the running level.** The running level should
describe the tape while it's moving. Two kinds of stopped second get counted anyway
(lines 171–174):

- the wait between pressing Record and starting the tape
- the first 50 or so seconds of a stop found by the 60-second rule

Enough of these pull the 20th percentile down to the floor, and then a real stop
looks normal and is never asked about.

**After the fix:**

- A floor counts as the stopped machine only if the detector heard it while
  listening before Record. Only that floor gets the 8-second rule.
- Any other floor needs a full 60 seconds, every time, not just the first time.
- Seconds that look stopped stay out of the running level, whether or not the
  question was raised.
- Recording still never stops by itself, and the detector still only reads audio.

**The costs.** There are two, and I recommend accepting both.

- **Slower without listening.** If the stopped machine wasn't heard before Record,
  the end of the tape is found after about a minute, not 8 seconds. That is what
  stops the false questions in short gaps.
- **One more way to get a question in a long gap.** Keeping stopped-looking seconds
  out of the running level also keeps out some seconds that were running tape:
  blank leader or a gap that opens the recording on a tape that was already
  rolling. After that, a later gap of 60 seconds or more can ask where today it
  wouldn't. Gaps under 60 seconds stay quiet, so Bug 1 stays closed. See Risks.

## The rules, precisely

These are the rules once Phases 2–5 land. Phases 4 and 5 are optional and marked.

### Terms

| Term | Meaning |
|---|---|
| Second | One level reading: the 5th-lowest of ten 100 ms readings in the band. Unchanged. |
| Floor | The quietest second heard, over the last 30 listened seconds before Record and every second since. Digital silence (−130 dB or lower) never counts. Unchanged. |
| Heard floor | The floor as it stood when Record was pressed, kept only if listening supports it (see below). New. |
| At the floor | Within `nearFloor` (2.5 dB) above the floor. Unchanged. |
| Quiet run | Seconds in a row at the floor. A drop of more than 2.5 dB to a new floor starts a new run. Unchanged. |
| History | Seconds believed to be running tape. The running level is its 20th percentile, and it needs 30 entries. |

### When the floor is confirmed

1. **At Record**, take the listened seconds (up to 30, digital silence removed). The
   floor is the quietest. If at least **5** of them are within 2.5 dB of the
   quietest, that level becomes the heard floor. Otherwise there is no heard floor.
2. **The floor is confirmed** while a heard floor exists and the floor is no more
   than 2.5 dB below it. A floor that drifts down a little stays confirmed. A floor
   that falls further, in one step or by creeping, is unconfirmed.
3. **Nothing during the recording confirms a floor.** That includes a stop found by
   the 60-second rule and the wait before the tape starts.

Why 5 seconds: one short pause between songs, caught while listening to a playing
tape, must not count as the stopped machine. A stopped machine sits at its level for
as long as it's stopped.

Why rule 3: the brief allowed "a later confirmed stop" to earn the 8-second rule. I
recommend against it. A long gap followed by Keep Recording looks the same to the
detector as a real stop followed by rethreading. Promoting the floor after either
would bring Bug 1 back after one long gap. Not promoting costs 52 seconds on a second
stop, and only in sessions where the stopped machine was never heard.

### When it asks

A quiet run raises the question when both are true:

- the run has lasted **8 seconds** if the floor is confirmed, or **60 seconds** if
  it isn't
- the running level is at least `runningGap` (3 dB) above the floor

The check runs every second of the run, so a run that outlasts its wait still asks
once history fills.

### What enters history

A second above the floor goes into history at once, unless the question is up.

A second at the floor is held back until its quiet run ends. The run's seconds then
go into history unless the run looked stopped:

| The run | History? | Why |
|---|---|---|
| Had the question raised, or sat under Keep Recording | Never | It was a stop, or the user was asked about it |
| Opened the recording (began on its first second) and ended with the level rising | No | Usually the wait before the tape started. A guess, see below |
| Lasted the full 8 or 60 seconds while there wasn't enough history to judge it, and ended with the level rising | No | It met the detector's own test for a stop. Also a guess |
| Ended because a floor more than 2.5 dB lower arrived, with no question raised | Yes | Something quieter exists, so this was running tape |
| Anything else: a short dip, or a gap under 60 seconds on an unconfirmed floor | Yes | A gap. This is how the tape's quiet level is learned |

**Rows 2 and 3 are guesses, and they can be wrong.** With no heard floor, the
detector can't tell the wait before Play from blank leader or a gap on a tape that
was already rolling when Record was pressed. Both are a stretch at the only floor it
knows, ended by the level rising. So these rows also drop running tape:

- blank leader or a gap that the recording opens in, of any length
- a gap of 60 seconds or more that comes before there are 30 seconds of history

Those seconds never teach the running level how quiet the tape gets. I recommend
dropping them anyway. Keeping them brings Bug 2 back for every wait before Play, and
a stop that is never asked about is worse than one extra question. The price is
under Risks.

**Digital silence** (−130 dB or lower) never enters history or the held-back run.
That is part of Phase 3 and doesn't wait for Phase 4. A digitally silent second also
isn't counted as a second of the recording, so "opened the recording" means the
first real second. Until Phase 4 it still counts towards the length of a quiet run,
as it does today.

### Withdrawing and Keep Recording

- **Today:** one second more than 3 dB above the floor withdraws the question.
- **Phase 5, optional:** it takes 3 such seconds in a row, the same test Keep
  Recording already uses to re-arm.
- **Keep Recording** is unchanged: nothing is asked until the tape has run for 3
  seconds.

### The logic in code

A sketch of the per-second logic as Phase 3 leaves it, to pin down ordering. It is
complete without Phase 4. The names are suggestions.

```swift
private var heardFloor: Double?        // Phase 2
private var pending: [Double] = []     // Phase 3: the current quiet run, held back
private var runWasStopped = false      // Phase 3: question raised or Keep Recording
private var runOpensRecording = false  // Phase 3
private var runUnjudged = false        // Phase 3: long enough, but no history yet

private var floorConfirmed: Bool { heardFloor.map { floor >= $0 - nearFloor } ?? false }

private mutating func finishSecond(_ level: Double) {
    // Digital silence is a missing input. It never sets the floor, never counts as
    // a second of the recording and is never kept. It still extends a quiet run, as
    // today. Phase 4 replaces `silent` with an early return here.
    let silent = level <= -130
    if !silent {
        second += 1
        if level < floor - nearFloor { endRun(lowerFloor: true) }
        if level < floor { floor = level }
    }

    // A silent second is always at the floor, because the floor is never set by
    // one. So it can't reach the `history.append` below.
    let atFloor = level <= floor + nearFloor
    if atFloor {
        quietRun += 1
        if !silent {
            if pending.isEmpty { runOpensRecording = second == 1 }
            pending.append(level)                      // keep the newest historyLimit
        }
    } else {
        endRun(lowerFloor: false)
    }

    judge(level)

    if atFloor {
        if machineStopped || dismissed { runWasStopped = true }
    } else if !machineStopped {
        history.append(level)
    }
    // trim history to historyLimit
}

private mutating func endRun(lowerFloor: Bool) {
    let looksStopped = runWasStopped || (!lowerFloor && (runOpensRecording || runUnjudged))
    if !looksStopped { history.append(contentsOf: pending) }
    pending = []
    quietRun = 0
    runWasStopped = false; runOpensRecording = false; runUnjudged = false
}

// In judge, after the dismissed and machineStopped branches:
guard quietRun >= (floorConfirmed ? stoppedSeconds : unconfirmedSeconds) else { return }
guard let running = runningLevel else { runUnjudged = true; return }
machineStopped = running >= floor + runningGap
```

`runningLevel` becomes the 20th percentile of `history` with no `dropLast`, because
the current run is no longer in it. `recent` and `floorSetAt` go away.

Two places can add to `history`: the `append` for a second above the floor, and
`endRun` committing `pending`. Neither can carry digital silence. A silent second is
never above the floor, and it is never put in `pending`.

### What should happen, case by case

"Heard" means the stopped machine was heard for 5 or more seconds before Record.
"Enough tape" means 30 seconds or more above the floor, which is `minimumHistory`.
With less, there is no running level and nothing is asked, today and after.

| Situation | Today | After |
|---|---|---|
| Heard, tape plays, machine stops | Asks at 8 s | Same |
| Heard, gaps of blank tape | Never asks | Same |
| Not heard, busy tape, first gap under 60 s | Quiet | Same |
| Not heard, busy tape, second gap at the same level | **Asks at 8 s** | Quiet |
| Not heard, any gap over 60 s | Asks, by design | Same |
| Not heard, machine stops | Asks at 60 s the first time, 8 s after that | Asks at 60 s each time |
| Not heard, but the recording opens with the machine stopped | Asks at 8 s | Asks at 60 s |
| Heard, 2 minutes waiting after Record, enough tape but under about 8 minutes (four times the wait), stop | **Never asks** | Asks at 8 s |
| Not heard, same | **Never asks** | Asks at 60 s |
| Either, a wait after Record, under 30 s of tape, stop | Never asks, because the wait is in the history | Never asks, because there is too little tape to judge |
| Stop found at 60 s, Keep Recording, enough tape, stop | **Can miss it** | Asks at 60 s |
| Not heard, tape rolling, recording opens in blank leader or a gap, then a later gap under 60 s at that level | Quiet | Same |
| Not heard, same opening, then a later gap of 60 s or more at that level | Quiet while such seconds are a fifth of the history | **Asks at 60 s** until gaps under 60 s make up a fifth of the history. A cost, see Risks |
| Listening caught only a 2–3 s pause on a playing tape | Later gaps ask at 8 s | Quiet for gaps under 60 s |
| Listening caught 5 s or more of blank tape rolling, and nothing quieter | Later gaps ask at 8 s | Same. A limit, see Risks |
| Tape's blank level within 2.5 dB of stopped, gaps of 8 s or more | Asks in gaps | Same. A limit |
| Tape that dips to the floor often, in dips under 8 s | Quiet, and blind to the stop | Same |

## Ground rules for every phase

- **Branch:** work only in `/Users/colton/code/me/macos/audio-archive-machine-stop`
  on `machine-stop`. Don't touch `~/code/me/macos/audio-archive`. Don't merge into
  `redesign` and don't push. Commit only if the pipeline asks for it.
- **Recording never stops by itself.** The detector only sets or clears
  `machineStopped`. No phase adds a call to `stopRecording`.
- **The detector only reads buffers.** No phase adds file, database or network
  access to `MachineStopDetector` or changes what `AudioCapture.process` writes.
- **The real library is off limits.** No phase opens `~/Music/Remanence`. Never set
  `REMANENCE_STOP_CHECK` to it in this work. That run is Colton's, after the code
  lands.
- **No phase needs the app running.** If someone launches it anyway, it must be
  `open -g .build/xcode/Build/Products/Debug/Remanence.app --args -siteURL http://127.0.0.1:9 -libraryPath "$TMPDIR/remanence-scratch-ms"`.
  Leave any Remanence that is already running alone.
- **Don't delete anything in `$TMPDIR`.** That covers scratch recordings under
  `$TMPDIR/remanence-scratch-ms`, the scratch file Phase 6 writes, and anything
  already there. Leave them in place and don't overwrite them. Report what was
  added and where, so Colton can clear it himself.
- **Files in scope:** `MachineStopDetector.swift`, the `MachineStopDetectorTests`
  suite in `RecordingTests.swift`, the two docs in Phase 7, and in Phase 5 only,
  the `alert` helper in `Remanence/RecordModel.swift` and one of its calls.
  `AudioCapture.swift` needs no change.
- **If a predicted window is off,** widen the test's window by a second or two and
  say so. If a test fails for a real reason, stop and report it. Don't change
  `nearFloor`, `runningGap`, `stoppedSeconds` or `unconfirmedSeconds` to make a test
  pass.

Check after each phase:

```bash
swift test --package-path RemanenceCore --filter MachineStopDetectorTests
swift test --package-path RemanenceCore
```

## Phases

Each phase builds and passes by itself. Phases 2, 3, 4 and 5 start by adding their
tests and confirming they fail for the reason given, then make the change.

### Phase 1: a test feeder that can be strict, and tests that already pass

No detector changes. This phase gives later phases the tools they need and locks in
behaviour that must survive them.

**File:** `RecordingTests.swift`, the `MachineStopDetectorTests` suite.

**Approach.** Extend `Feeder`:

- **Listening.** Feeding before `beginRecording()` is listening. Add a way to start
  with nothing heard (today's `Feeder()`) and a helper that has heard the stopped
  machine for 6 seconds, for example `Feeder.heardStopped()`.
- **Levels.** Add noise at any level relative to stopped, for example
  `.noise(above: 3.5)`. `.stopped` is 0 dB and `.blankTape` stays 6 dB.
- **Format.** Make the sample rate, channel count and block size settable. Each
  channel needs its own noise. Add a way to put the tape on one channel only, with
  stopped-level noise on the other.
- **Timing.** Count the flagged second from frames fed, so odd block sizes work.
- **Gaps.** Let `playTape` take the blank level.
- **Digital silence.** Add a `.digitalSilence` sound, all zeros. Phases 3 and 4 use
  it.

Before adding tests, run the suite once and note how many tests the runner reports.
The doc says 429 and the folder has 476 `@Test` attributes.

**Tests, all expected to pass on today's code:**

| Test | Scenario | Expect |
|---|---|---|
| `oddBlockSizesGiveTheSameAnswer` | 8 kHz mono, 333-frame blocks. Heard, 3 minutes of tape, stop. | Asks at 7–9 |
| `itWorksAtNinetySixKilohertzInStereo` | 96 kHz, 2 channels, 1024-frame blocks. Heard, program 20 s, blank 20 s, stop for 15 s. Keep it this short, for speed. | Nothing during the tape. Asks at 7–10 |
| `tapeOnOneInputOfAStereoPair` | 8 kHz, 2 channels, tape on the first only. Heard, 2 minutes of tape, stop. | Nothing during the tape. Asks at 7–9 |
| `aThinMarginStillWorks` | Heard. 3 minutes of tape with blank at +3.5 dB. Stop at +2 dB, the drift seen on RA-012 A. | Nothing during the tape. Asks within 8–40 s |
| `aDenseTapeStartedRollingStillFindsTheStop` | Nothing heard. Program for 300 s, then stop for 90 s. | Asks at 58–61 |
| `onlyTheLastHalfMinuteOfListeningCounts`, rewritten | Listen to noise at −14 dB for 20 s (knob down), then stopped for 40 s. Record, 2 minutes of tape, stop. | Asks at 7–9. It fails if old listening is kept, because the floor would be 14 dB too low |
| `listeningToAPlayingTapeForgetsTheStoppedMachine` | Listen to stopped for 20 s, then program for 40 s. Record, program 60 s, stop for 90 s. | Nothing in the first 30 s of the stop. Asks at 58–61. It fails if old listening is kept, because it would ask at 8 |

A note on `aThinMarginStillWorks`: the stop sits about 2.3 dB above the floor, since
the floor is the quietest of several noisy seconds. That is close to the 2.5 dB
limit, so the detector should find 8 clean seconds within about 12 on average. If it
takes longer than 40 on today's code, don't touch the detector. Lower the drift to
+1.5 dB, keep the +2 dB figure in a comment, and report it. It is a finding about
`nearFloor`, which this plan doesn't change.

**Acceptance:** all suites pass with `MachineStopDetector.swift` untouched. The 96 kHz
test finishes in a few seconds in a debug build.

### Phase 2: only a heard floor gets the 8-second rule (Bug 1)

**Files:** `MachineStopDetector.swift`, `RecordingTests.swift`.

**Approach.**

- Add `listeningConfirmSeconds = 5` and `heardFloor`.
- In `beginRecording()` (lines 105–119), set `heardFloor` by rule 1 above.
- Replace `knownBefore` (line 189) with `floorConfirmed`. Remove `floorSetAt`.
- Leave `recent`, `history` and `runningLevel` alone. They are Phase 3.
- Update the type's doc comment. It still says the first quiet stretch waits a
  minute, where now every stretch on an unconfirmed floor does.

Why this is safe before Phase 3: with a floor that isn't confirmed, no gap can use
the 8-second rule, so Bug 1 no longer depends on the running level at all.

**Existing tests.** These currently learn the floor from 3 stopped seconds after
Record. That no longer confirms it, and in the app the floor comes from listening.
Move them to `Feeder.heardStopped()`: `blankGapsOnATapeAreNeverFlagged`,
`theMachineStoppingIsNoticedQuickly`, `theReelsLooseEndSlappingDoesNotHideTheStop`,
`itStaysStoppedThroughALongIdle`, `itClearsWhenTheTapeRunsAgain`,
`keepRecordingWaitsForTheTapeToRunAgain`. Their expectations don't change.

**New tests:**

| Test | Scenario | Expect | Today |
|---|---|---|---|
| `aSecondGapOnADenseTapeIsNotAStop` | Nothing heard. Program 600 s, blank 30, program 60, blank 30, program 60, blank 45, program 60, then stop for 90 s. | Nothing in any gap. The stop asks at 58–61 | Asks about 8 s into the second gap |
| The same, having listened to the playing tape | Listen to program for 40 s first. | Same | Same failure |
| `aShortPauseHeardWhileListeningIsNotTheStoppedFloor` | Listen to program for 27 s, then blank for 3 s. Record, program 120 s, blank 30 s. | Nothing | Asks in the gap |
| `aStopAfterOnlyAnOpeningPauseTakesAMinute` | Nothing heard. Stopped 3 s, 3 minutes of tape, stop for 90 s. | Asks at 58–61 | Asks at 7–9 |
| `aFloorThatCreepsBelowTheHeardOneIsUnconfirmed` | Heard. 1 minute of tape. Then noise at −1, −2, −3, −4, −5 and −6 dB for 2 s each, then −6 dB for 30 s. | Nothing | Asks, because small steps never counted as a new floor |
| `aFloorWellBelowTheHeardOneIsUnconfirmed` | Heard. 2 minutes of tape. Then noise at −8 dB for 90 s. | Nothing for 30 s. Asks at 58–61 | Passes already. Kept to lock it in |
| Extend `listeningBeforeRecordTeachesTheStoppedFloor` | After its 90 s gap, stop. | Asks at 7–9 | Passes already |

**Acceptance:**

- The new tests pass, and the first five failed before the change for the reason in
  the last column.
- Phase 1's tests still pass.
- `aTapeNoQuieterThanAStoppedMachineIsLeftAlone` still passes. Phase 3 replaces it.

### Phase 3: keep stopped-looking seconds out of history (Bug 2)

**Files:** `MachineStopDetector.swift`, `RecordingTests.swift`.

**Approach.** Replace `recent` and its `stopped` marks with the held-back run in the
sketch above:

- `pending` holds the current quiet run. `endRun` decides whether it joins history,
  by the table under "What enters history".
- Seconds above the floor join history at once, unless the question is up. The old
  10-second delay goes.
- `runningLevel` drops its `dropLast`.
- `judge` sets `runUnjudged` when a run is long enough but there's no running level.
- **Digital silence never enters `pending` or `history`, and this phase guarantees
  it without Phase 4.** Follow the sketch's `silent` flag. A second at −130 dB or
  lower:
  - doesn't lower the floor and doesn't end a run as "a lower floor arrived". This
    is today's `level > -130` guard (line 156), kept around both lines.
  - isn't appended to `pending`
  - isn't counted in `second`
  - still adds one to `quietRun`, as today. Only Phase 4 changes that.

  It can't take the other path into `history` either, because a silent second is
  never above the floor. Today it does get in, through `recent` (lines 153 and
  171–174), so this is a fix and has a test below.
- Cap `pending` at `historyLimit`. `beginRecording()` resets all the new state.
- Update the doc comments on `history` and `minimumHistory`. The second becomes
  "seconds of running tape needed before judging".

**The trap to avoid.** Don't drop the opening run unconditionally. On a tape started
rolling, the opening run is the program itself, sitting at its own floor. It must
join history when a lower floor arrives, or the detector has no history and never
asks. `aDenseTapeStartedRollingStillFindsTheStop` from Phase 1 guards this.

**New tests:**

| Test | Scenario | Expect | Before this phase |
|---|---|---|---|
| `waitingAfterRecordDoesNotHideTheStop` | Heard. Stopped 120 s, program 60 s, stop. | Asks at 7–9 | Never asks |
| The same, nothing heard | Stopped 120 s, program 60 s, stop for 90 s. | Asks at 58–61 | Never asks |
| `aStopFoundAfterAMinuteDoesNotHideTheNext` | Nothing heard. Program 60 s, stop until it asks (58–61), Keep Recording, stopped 10 s more, program 60 s, stop for 90 s. | Asks again at 58–61 | Never asks the second time |
| `aPauseBeforeThereIsHistoryDoesNotHideTheStop` | Heard. Stopped 5 s, program 10 s, stopped 20 s, program 60 s, stop. | Nothing in the pause. Asks at 7–9 | Never asks |
| `aTapeThatKeepsDippingToTheFloorIsLeftAlone` | Heard. Eighteen rounds of program 6 s then stopped-level 4 s, then stopped for 60 s. | Nothing, including the last minute | Replaces `aTapeNoQuieterThanAStoppedMachineIsLeftAlone` |
| `nothingIsSaidBeforeThereIsHistory`, rewritten | Heard. Program 10 s, stopped 20 s. Then program 40 s, stop. | Nothing in the first stop. Asks at 7–9 in the second | The old version passes for the wrong reason |
| `aTapeTooShortToJudgeIsLeftAlone` | Nothing heard. Stopped 60 s, program 20 s, stopped 120 s. The scenario of the removed test, under a true name. | Nothing | Passes already, for a different reason. See below |
| `digitalSilenceNeverReachesTheRunningLevel` | Heard. Program 40 s, then eight rounds of zeros 5 s and program 5 s, then stop. | Nothing during the rounds. Asks at 7–9 | Never asks. The 40 silent seconds are a third of the history, so the running level reads −150 dB |
| `anOpeningGapOnARollingTapeIsNotLearned` | Nothing heard. Blank 40 s, program 60 s, blank 20 s, program 60 s, blank 90 s. | Nothing through the 20 s gap. The 90 s gap asks at 58–61 | Nothing anywhere. This test pins a cost. See below |

**Removing `aTapeNoQuieterThanAStoppedMachineIsLeftAlone`.** Its scenario is 60 s
stopped, 20 s of program, then 120 s stopped (`RecordingTests.swift:333-338`), and
it must still not ask after this phase. What changes is why:

- **Today** the 60-second wait is in the history, so the running level sits at the
  floor and the 3 dB check fails.
- **After** the wait is dropped, which leaves 20 seconds of program. That is under
  `minimumHistory` (30), so there is no running level and nothing is judged.

So the test would keep passing, but its name and comment say it shows a tape that
can't be told from a stopped machine. After this phase it shows a tape too short to
judge. Remove it under that name. Keep its scenario as
`aTapeTooShortToJudgeIsLeftAlone` with the true reason in its comment.
`aTapeThatKeepsDippingToTheFloorIsLeftAlone` takes over the 3 dB check. The scenario
that starts asking in this phase is `waitingAfterRecordDoesNotHideTheStop`, which
has 60 seconds of program.

**What `anOpeningGapOnARollingTapeIsNotLearned` is for.** It has two halves:

- **The 20-second gap stays quiet.** This must hold. It is Bug 1 on a tape whose
  opening was dropped from the history.
- **The 90-second gap asks at about 60.** This is the cost from "What enters
  history", and today it doesn't ask. The test pins it so the cost is visible and a
  later change to it is deliberate. Say so in the test's comment.

By hand: the opening 40 seconds are dropped, the 20-second gap joins the history,
and 20 quiet seconds out of 140 leave the 20th percentile at program level.

**Acceptance:**

- `waitingAfterRecordDoesNotHideTheStop`, its nothing-heard twin,
  `aStopFoundAfterAMinuteDoesNotHideTheNext`,
  `aPauseBeforeThereIsHistoryDoesNotHideTheStop` and
  `digitalSilenceNeverReachesTheRunningLevel` failed before the change and pass
  after. The last one passes with Phase 4 not built.
- `aTapeTooShortToJudgeIsLeftAlone` passes before and after.
- `anOpeningGapOnARollingTapeIsNotLearned` goes from no question to one question,
  in its last gap only. A question in its 20-second gap is a failure.
- Every test from Phases 1 and 2 still passes, above all the dense-tape ones.
- `recent` and `floorSetAt` no longer exist.

### Phase 4, optional: digital silence changes nothing

Included because it is one guard and three tests. Nothing depends on it. Phase 3
already keeps digital silence out of `pending`, `history`, the floor and the count
of seconds. What this phase adds is that silence stops counting towards a quiet run.

**Files:** `MachineStopDetector.swift`, `RecordingTests.swift`.

**Approach.** A second at −130 dB or lower returns at the top of `finishSecond`
before any state changes. It doesn't extend a quiet run, break one, raise the
question or withdraw it. The early return replaces Phase 3's `silent` flag, which
then has nothing left to do. The feeder's `.digitalSilence` comes from Phase 1.

**Tests:**

| Test | Scenario | Expect | Before |
|---|---|---|---|
| `digitalSilenceIsNotAStop` | Heard. 1 minute of tape, then zeros for 30 s. | Nothing | Asks at about 8 |
| `digitalSilenceDoesNotHideAStop` | Heard. 1 minute of tape, stopped 4 s, zeros 3 s, stopped 10 s. | Asks on the 8th stopped second | — |
| `digitalSilenceLeavesTheQuestionUp` | Heard. Tape, stop until asked, zeros 5 s. | Still stopped | — |

**Acceptance:** the tests pass and nothing earlier changes, including Phase 3's
`digitalSilenceNeverReachesTheRunningLevel`.

### Phase 5, optional: a bump doesn't re-alert

Included in part. The sound and the notification are not throttled, for the reason
given below.

**Files:** `MachineStopDetector.swift`, `RecordingTests.swift`, and
`Remanence/RecordModel.swift`: the `alert` helper (lines 525–533) and its call for
this question (line 488).

**Approach.**

- **Detector.** Once the question is up, withdraw it only after 3 seconds in a row
  more than 3 dB above the floor. Today one second does it (line 186). Reuse
  `runningAgain`, and reset it when the question is raised.
- **Notification.** Today `alert(sound:title:body:)` makes every request's
  identifier itself, with `UUID().uuidString` at `RecordModel.swift:531`. No caller
  passes one, so the call at line 488 has nothing to change yet. Two edits:
  1. Give `alert` a parameter, `identifier: String? = nil`, and use
     `identifier ?? UUID().uuidString` at line 531.
  2. Pass a fixed string, for example `"tape-finished"`, from the call at line 488
     only.

  A repeat then replaces the earlier banner and they don't stack. The other callers
  (lines 367, 477 and 510, and `throttledAlert` at 520) are not edited and keep
  unique identifiers through the default.

**Why no time-based throttle.** A throttle would silence the sound for a real second
stop soon after Keep Recording, and the sound is how the user hears about it from
across the room. Fixing the cause in the detector is testable and leaves the sound
alone.

**Tests:**

| Test | Scenario | Expect |
|---|---|---|
| `aBumpDoesNotWithdrawTheQuestion` | Heard. Tape, stop until asked, blank tape for 2 s, stopped 5 s. | Still stopped throughout |
| `itClearsWhenTheTapeRunsAgain`, updated | Feed 4 s of blank tape, where it fed 2. | Cleared |

**Acceptance:**

- Core tests pass.
- The app builds:
  `xcodebuild -project Remanence.xcodeproj -scheme Remanence -destination 'platform=macOS' -derivedDataPath .build/xcode build`.
- The `RecordModel` change is only the new `identifier` parameter, its use at line
  531 and the one argument at line 488. `askingIfFinished`, `keepRecording()`, the
  other `alert` callers and the stop paths are untouched. There is no app test
  target, so this part is checked by reading the diff.

### Phase 6: make the real-masters check match the new rules

The detector no longer treats the opening seconds of a file as a known floor, so
`realMasters` as written would report every stop a minute late. The app always
listens before Record, and the check should imitate that.

**File:** `RecordingTests.swift`, `realMasters` only.

**Approach.** Run each file twice and print both:

- **cold:** as now, with nothing heard before Record
- **primed:** feed the file's first second six times as listening, call
  `beginRecording()`, then feed the whole file from the start. This assumes the app
  heard, just before Record, what the file opens with.

Keep it read-only: `AVAudioFile(forReading:)` and `print`, nothing else. Keep the
`REMANENCE_STOP_CHECK` gate. Still no assertions, because it is a measuring tool.

**Check without the real library.** Make one short file with `ffmpeg` in
`"$TMPDIR/remanence-scratch-ms/masters/"`: 5 s of quiet white noise, 60 s of noise
about 6 dB louder, then 30 s at the quiet level again. Give it a name that can't
collide with a recording, such as `stop-check-scratch.wav`, and run `ffmpeg` with
`-n` so it never overwrites. If the file is already there from an earlier run, use
it as it is. Then:

```bash
REMANENCE_STOP_CHECK="$TMPDIR/remanence-scratch-ms" \
  swift test -c release --package-path RemanenceCore --filter MachineStopDetectorTests
```

The check reads every `.caf` and `.wav` under that `masters` folder, so scratch
recordings already there print lines too. That is fine. It only reads them.

**Acceptance:** for the scratch file, the primed line reports a question about 8 s
into the last quiet part, and the cold line reports none within the file. The real
library is not read.

**Leave the scratch file where it is.** Don't delete it, or anything else in
`$TMPDIR`, when the check is done. Report its path.

### Phase 7: correct the docs

**Files:** `docs/machine-stop-detector.md`, and one sentence in
`docs/native-app-plan.md`.

**In `machine-stop-detector.md`:**

- **The solution.** Remove "The second condition is what makes gaps harmless" and
  the sentences after it. Say what is true: the 8-second rule needs a floor heard
  while listening, any other floor needs 60 seconds every time, and the 3 dB check
  only helps on tapes that dip to the floor often.
- **Details.** Rewrite "When the stopped machine was never heard" to match rule 3.
  Add the 5-second listening rule and what stays out of the running level. Correct
  "middle tenth (the median)" to the 5th-lowest of ten. Say that digital silence
  never sets the floor or reaches the running level (Phase 3). Describe whether it
  counts towards a quiet run, and how the question withdraws, as the code now has
  them, depending on Phases 4 and 5.
- **Two bugs found along the way.** Add the two from this pass.
- **Tests table.** Match the suite. Change "No judgment before 30 seconds of
  recording" to 30 seconds of running tape. Mention the one-hour history cap. Use
  the test count the runner reports.
- **The gated command.** Add `-c release` and describe the cold and primed passes.
- **Results.** Keep the table, and say plainly that it was measured on 2026-11-25
  with the earlier rules and has not been re-run. Say that with nothing heard before
  Record, those stops would now be found after about a minute. Don't add new
  figures.
- **RA-002 and RA-004.** Say these are the "tape no louder than a stopped machine"
  case, not a special case of old exports.
- **Limits.** Replace the first bullet. The detector does not "stay quiet rather
  than guess". Write the limits from Risks below: a tape within 2.5 dB of stopped
  asks in gaps of 8 seconds or more, a tape started more than 30 seconds before
  Record can teach the wrong floor, a gap over 60 seconds asks, a floor that falls
  below the stopped machine blinds it, and stereo with tape on one input loses
  margin. Add the two this plan makes plainer: blank leader or a gap that opens the
  recording on a rolling tape is not learned, so a later gap of a minute or more
  can ask, and a tape with under 30 seconds of running tape is never judged.
- **Live testing.** State that it has still not run during a real recording, and
  point to the trial list in this plan.
- **Header.** Fix the date line. The change was made on 2026-11-24 and the code is
  committed on `machine-stop`.

**In `native-app-plan.md`:** at the sentence about `MachineStopDetector` (line 60),
add "tuned on recorded masters, not yet tried live", as the assessment asked.

**Acceptance:** no sentence in the doc claims more than a test or a measurement
shows. Nothing but docs changes.

## Risks

### False questions that remain

- **Listening heard the tape, not the machine.** If the tape has been playing for
  the whole 30 seconds before Record, and 5 or more of those seconds were its
  quietest level, that level becomes a confirmed floor. Later gaps or quiet passages
  at that level ask after 8 seconds. This exists today. The 5-second rule narrows it
  but doesn't close it. Closing it means knowing the machine's state, which the
  detector can't.
- **A tape no louder than the stopped machine.** With blank tape within 2.5 dB of
  stopped, gaps of 8 seconds or more ask. Phase 3 can make this more frequent.
  Today a wait before Play often sits in the history and silences everything,
  these gaps and the real stop alike, which is Bug 2. With the wait dropped, both
  are asked about. The doc must stop claiming such a tape is left alone.
- **A gap of 60 seconds or more on an unconfirmed floor asks.** By design, and
  Phase 3 makes it somewhat more likely. The 3 dB check only holds such a question
  back while at-floor seconds are about a fifth of the history. Today every
  at-floor second that wasn't flagged counts towards that fifth. After Phase 3 two
  kinds no longer do:
  - blank leader or a gap that the recording opens in, on a tape that was already
    rolling with no stopped machine heard
  - a gap of 60 seconds or more that came before there were 30 seconds of history

  The detector drops these because they look exactly like the wait before Play. So
  on a tape started rolling, the first later gap of a minute or more can ask where
  today it would stay quiet. If the opening leader was most of the side, today
  could never ask in such a gap and after Phase 3 it does. Gaps under 60 seconds
  still join the history, and once they make up a fifth of it the long gaps go
  quiet again.

  What this doesn't change: gaps under 60 seconds on an unconfirmed floor never
  ask, whatever is in the history, so Bug 1 stays closed. A session where the
  stopped machine was heard isn't affected either, because blank tape sits above a
  heard floor and joins the history as it arrives. The cost is one extra question,
  answered with Keep Recording. Recording carries on throughout.
  `anOpeningGapOnARollingTapeIsNotLearned` pins both halves.

### Missed or late stops

- **A minute, not 8 seconds,** whenever the stopped machine wasn't heard: Record
  within 5 seconds of opening the screen or changing the input, or with the tape
  already playing. This is the price of fixing Bug 1.
- **A tape that dips to the floor in short dips for a fifth of its length** is never
  asked about, as today.
- **Under 30 seconds of running tape is never judged.** A wait, 20 seconds of tape
  and a stop gets no question, today or after. Today the wait hides it. After, the
  history is too short (`minimumHistory`). Phase 3 fixes the wait only for tapes
  with 30 seconds or more above the floor.
- **The floor only falls.** One moment quieter than the stopped machine, such as the
  Teac switched off, lowers it for the whole side. The stopped machine then sits
  above the floor and nothing asks. Unchanged, and now also unconfirmed.
- **Keep Recording during a blank tail.** If the tape then runs out, the floor drops
  but the detector is still waiting for the tape to "run again", so it never asks.
  Unchanged. See Follow-ups.
- **Thin margins are unchanged.** `nearFloor` and `runningGap` keep their values.
  `aThinMarginStillWorks` measures the edge but doesn't widen it.

### Recordings and data

- **None of the phases can stop a recording.** The only stop paths remain the
  button, an interruption and a full disk, all outside this work.
- **Nothing writes.** The detector stays a value type that reads buffers.
  `AudioCapture.process` builds the file's payload before the detector runs, and
  this plan doesn't touch that file.
- **Cost on the processing queue.** `pending` adds one append per second. The
  percentile sort runs no more often than today. No new work per sample.
- **The gated test** stays read-only and stays gated. Phase 6 runs it only against
  a scratch folder.
- **`$TMPDIR` only grows.** Phase 6 adds one small file there and the live trial
  adds recordings. Nothing in this plan deletes or overwrites anything in
  `$TMPDIR`. A 96 kHz stereo reel is large, so the trial should report the
  folder's size for Colton to clear.
- **Phase 5 touches `RecordModel`,** by one optional parameter on `alert`, its use
  where the identifier is made, and one argument at the call. That is the only edit
  outside `RemanenceCore`, and Phase 5 is optional.

### Risks in the plan itself

- **Predicted, not run.** The traces could be wrong by a second, or a scenario could
  behave differently with real noise. The ground rules say what to do: adjust the
  window, never the thresholds, and report.
- **Phase 2 changes the meaning of six existing tests' setup.** They move to a
  listening start. Their expectations must not be loosened in the move.

## Left for the live Teac trial

Nothing below has been done. It happens after the code lands, with Colton's
go-ahead, into a scratch library with the launch line from the ground rules.
Recording makes real files and captures real sound, so say so first, check
`scripts/dev/micuse.swift` and keep it as short as a reel allows. Quit normally so
the input's sample rate is restored.

**Leave the test recordings where they are.** They land in
`$TMPDIR/remanence-scratch-ms`, and nothing in `$TMPDIR` is to be deleted. The
project rule to remove test recordings is about keeping them out of the real
library, and these never go near it. When the trial ends, tell Colton the folder
and its size so he can clear it himself.

1. **Usual start.** Machine stopped, Record, then Play. Record one reel through
   run-out. Expect no question during the tape and one within about 10 seconds of
   the stop.
2. **Started rolling.** Play for more than 30 seconds, then Record. Expect no
   question in gaps under a minute and one about a minute after the stop. Note
   whether a gap ever asks at 8 seconds, which would be the listening limit above.
   If Record lands in leader or a gap, note whether a later gap of a minute or
   more asks, which is the cost described under Risks.
3. **A long wait.** Record, wait 2 minutes, play a few minutes, stop. Expect a
   question within about 10 seconds.
4. **Pause mid-tape** for 20 seconds. Expect a question at about 8 seconds that
   withdraws when the tape runs.
5. **Keep Recording once,** then let it run out again.
6. **Rewinding while listening.** See what level the band reads during rewind and
   fast-forward. If it is below the stopped level, it will set a floor that is too
   low.
7. **Stereo, 96 kHz.** Check the saved file with `ffprobe` and note the dropout
   count.
8. **Notifications.** Count the alerts during a bumpy run-out.
9. **Then, with the app quit,** re-run `realMasters` in release against the real
   library and compare both passes with the doc's table. It only reads.

After the trial, write the real results into `machine-stop-detector.md`.

## Follow-ups

- Re-arm after Keep Recording when a new, lower floor arrives. One line in the
  floor-drop branch, but it changes what Keep Recording promises, so it needs
  Colton's say.
- A floor that can rise again, so one quiet moment doesn't blind a whole side.
- Tolerating one stray second in a quiet run, which would widen the `nearFloor`
  margin.
- Judging stereo channels separately.
- Guarding the filters against a NaN sample.
- A long-quiet fallback for tapes the detector can't judge.
- Cassette and microcassette machines, with Dolby.
- Keeping the analysis scripts, and a held-out recording to check thresholds on.

## Out of scope

- Changing `nearFloor`, `runningGap`, the band or the two waits.
- Renaming `dismissTapeEnd()`, `tapeEndQuestion`, `askingIfFinished` or
  `tapeFinishedConfirmed()`.
- The wording on screen and in the notification.
- Whether the question should latch until answered.
- `AudioCapture.swift`, `RecordView`, and anything in Review, Edit, Shelf, site push
  or processing.
- Merging into `redesign`, pushing, deploying, or touching the site repo.
- The live trial and the real-library run. They follow this work.
- Clearing out `$TMPDIR`. Nothing in it is deleted by this work.

## Review changes

The review is in [machine-stop-plan-review.md](machine-stop-plan-review.md)
(grok-4.7, high effort). I checked each finding against the plan,
`MachineStopDetector.swift`, `RecordingTests.swift` and `RecordModel.swift`. All
five are correct and all five are fixed. None was rejected.

1. **[blocking] Deleting in `$TMPDIR`. Accepted.** The plan told the implementer to
   delete Phase 6's scratch file and to remove the live trial's recordings, which
   land in `$TMPDIR/remanence-scratch-ms`. Both instructions are gone. A ground
   rule now says not to delete or overwrite anything in `$TMPDIR`, Phase 6 and the
   trial say to leave their files in place and report them, and Phase 6 uses a
   distinct file name with `ffmpeg -n`.
2. **[minor] The reason for removing `aTapeNoQuieterThanAStoppedMachineIsLeftAlone`.
   Accepted.** I traced it again. After the opening wait is dropped, 20 seconds of
   program is under `minimumHistory`, so the scenario still must not ask. Phase 3
   now gives that reason, keeps the scenario as `aTapeTooShortToJudgeIsLeftAlone`,
   and names `waitingAfterRecordDoesNotHideTheStop` as the one that starts asking.
   The case table said "short tape" where it needed 30 seconds or more. It now
   says so and has a row for the shorter case. Risks lists it as a missed stop.
3. **[minor] Dropping an opening quiet run drops running tape too. Accepted.** The
   rule is unchanged, because the detector can't tell the wait before Play from
   leader or a gap on a rolling tape, and keeping those seconds would bring Bug 2
   back. The plan now says what it costs: in the summary, under "What enters
   history", in the case table, in Risks and in the doc's Limits. A new Phase 3
   test, `anOpeningGapOnARollingTapeIsNotLearned`, pins both halves: a short second
   gap stays quiet (Bug 1 closed) and a 90-second gap asks at about 60.
4. **[minor] Digital silence depended on optional Phase 4. Accepted.** The sketch
   is now the Phase 3 code. It has a `silent` flag that keeps such seconds out of
   `pending`, the floor and the count of seconds, and it notes why they can't reach
   `history` by the other path. Phase 3 has a test for it that passes with Phase 4
   not built. Phase 4 stays optional and only stops silence counting towards a
   quiet run. The feeder's `.digitalSilence` moved to Phase 1.
5. **[minor] The `RecordModel` citation. Accepted.** The identifier is made inside
   `alert` at `RecordModel.swift:531`, and the call at line 488 passes none. Phase
   5 now cites both, and says to add an optional `identifier` parameter and pass it
   from that one call.

Three things changed beyond the findings, all found while checking them:

- **Risks said Phase 3 doesn't make the "tape no louder than stopped" case worse.**
  That was the same overclaim as finding 3. It now says the questions can come
  more often, and why.
- **"Opened the recording" counts real seconds from Phase 3 on.** With nothing
  heard, a digitally silent first second would otherwise stop the wait before Play
  from being recognised. Phase 4 used to be what fixed that.
- **Two predictions are new and as untested as the rest:** the windows for
  `digitalSilenceNeverReachesTheRunningLevel` and
  `anOpeningGapOnARollingTapeIsNotLearned`. Both come from tracing by hand.
