# Telling a stopped machine from a silent tape

The detector was made on 2026-11-24 and is committed on the `machine-stop` branch.
A fix pass on 2026-11-25 changed its rules, following
[machine-stop-plan.md](machine-stop-plan.md). This describes the rules after that
pass.

## The problem

While a tape is recording, Remanence asks "Has the tape finished?" so a recording
doesn't run on after the reel is spent. The old detector, `TapeEndDetector` in
`LevelAnalysis.swift`, asked whenever the input went quiet for a while.

Reels often have long gaps between recordings, so the question kept coming up in
the middle of tapes. Nearly every time it asked, the tape was still playing.

**What matters isn't whether the tape is silent. What matters is whether the
machine has stopped,** with the tape run out, the Teac sitting idle, and Remanence
still recording. Four of the existing masters run 1.5–6 minutes past the end of
their tape for exactly this reason (see Results).

## Can you hear the difference at all?

A gap on a tape and a stopped machine both sound like nothing. Even so, tape moving
past the playback head adds a little noise of its own, from the oxide and the
transport. A stopped machine only passes on the noise of its electronics. The
question was whether that difference survives the trip through the Scarlett.

### First pass: the existing masters

Before any new recordings, I measured the masters already in
`~/Music/Remanence/masters/`. They were only read. Many have a few seconds of
blank tape before the program starts, and some end with the machine stopped.

- **Treble hiss is no help.** Above about 8 kHz, tape hiss is buried under the
  Scarlett's own noise. That's where you'd expect hiss to stand out, but at these
  levels the interface is louder.
- **The midrange is promising.** Blank tape before the program sat 3–6 dB above
  stopped stretches, roughly between 500 Hz and 2 kHz.

These were hints and not proof, because the recordings weren't made for the
purpose.

### Second pass: controlled recordings

You made two reference recordings with the same knob settings (Teac output 75%,
Scarlett gain about 25%):

| Recording | What it is |
|---|---|
| **RA-014 side B** ("Erase") | A mostly empty tape running: blank tape passing the head |
| **RA-015** ("MACHINE NOT RUNNING") | The Teac powered on, not running tape |

I compared their spectra band by band (ffmpeg's `astats` and short Python scripts
measuring each band's level second by second). The scripts were throwaway, in the
session scratchpad.

- **500 Hz–2 kHz: blank tape is 4–8 dB louder than a stopped machine.** That's
  the clearest and steadiest difference.
- **60 Hz on the left channel: 14 dB louder with the tape running.** It's large,
  but it appears on one channel only. It probably depends on the machine and how
  it's wired, so I didn't build on it.
- **Above 4 kHz: no difference.** This matches the first pass.
- **A check on the setup:** the first 1.2 seconds of RA-014 side B, before the
  tape started moving, match RA-015's level almost exactly. So the two recordings
  really were made at the same settings, and the comparison is fair.

## The solution: `MachineStopDetector`

`RemanenceCore/Sources/RemanenceCore/MachineStopDetector.swift` replaces
`TapeEndDetector`. In outline:

1. **Watch the 500 Hz–2 kHz band.** The input runs through a 500 Hz high-pass
   and a 2 kHz low-pass (second-order Butterworth biquads), and its level is taken
   once a second.
2. **Remember the floor.** The quietest second heard so far is the floor. The last
   30 seconds of listening before you press Record count too, because the machine
   is usually stopped then.
3. **Compare with the running tape.** The "running level" is the 20th percentile
   of the seconds believed to be running tape: how quiet the tape gets while it's
   moving, including the gaps it has learned. It needs 30 such seconds.
4. **Ask only when both are true:**
   - the band has sat at the floor (within 2.5 dB) for long enough: **8 seconds**
     if the floor was heard while listening, **60 seconds** if it wasn't, and
   - the running level is at least **3 dB** above the floor.

What protects gaps is mostly where the floor came from and how long the wait is. The
8-second rule needs a floor heard while listening before Record. Gaps of blank tape
that sit more than 2.5 dB above that floor aren't at it, so they never count. Any
other floor needs a full 60 seconds, every time, so shorter gaps on it never ask.
The 3 dB check only helps on tapes that dip to the floor often: once at-floor
seconds make up about a fifth of the running level's history, nothing is asked.

### Details

- **Reel slaps.** After a reel runs out, the loose end can slap the machine every
  few seconds as it turns. Each second is judged by the **5th-lowest of its ten
  100 ms readings**, so a slap doesn't make a stopped second look like running
  tape.
- **Confirming the floor.** When Record is pressed, the quietest of the listened
  seconds becomes the floor. It counts as the stopped machine only if at least
  **5** of those seconds were within 2.5 dB of it, so one short pause caught while
  listening to a playing tape doesn't pass for it. The floor stays confirmed while
  it's no more than 2.5 dB below that heard level. If it falls further, in one step
  or by creeping, it's unconfirmed.
- **When the stopped machine was never heard.** This happens when Record is pressed
  within 5 seconds of opening the recording screen, changing the input or finishing
  a side, and usually when the tape is already playing (see Limits for the
  exception). Every quiet stretch then needs **60 seconds**. Nothing heard
  during the recording confirms a floor: not a stop found by the 60-second rule,
  and not the wait before the tape starts. A long gap followed by Keep Recording
  looks the same to the detector as a stop followed by rethreading. The price is
  that a second stop in such a session also takes a minute.
- **What counts as running tape.** A second above the floor counts at once, unless
  the question is up. Seconds at the floor are held back until that quiet stretch
  ends. The stretch is then left out if:
  - the question was raised during it, or it sat under Keep Recording, or
  - it began on the recording's first second and ended with the level rising
    (usually the wait before the tape started), or
  - it lasted the full 8 or 60 seconds before there was enough history to judge it,
    and ended with the level rising.

  Anything else counts: a short dip, a shorter gap on an unconfirmed floor, or a
  stretch cut off by a floor more than 2.5 dB lower with no question raised. The
  second and third rules are guesses, and they can leave out real running tape (see
  Limits). Only the last hour of running tape is kept.
- **Keep Recording.** Dismissing the question keeps it quiet until the tape has
  clearly run again, more than 3 dB above the floor, for 3 seconds in a row.
- **It clears itself.** If the tape runs that way for 3 seconds in a row before you
  answer, the question goes away. A shorter bump leaves it up.
- **Alerts.** Each new question plays a sound. Its notification always has the same
  identifier, so a repeat should replace the earlier one rather than stack. That
  hasn't been watched in the running app.
- **Digital silence** (all zeros, as from a missing input) changes nothing. It never
  sets the floor or reaches the running level, it neither extends nor breaks a quiet
  stretch, and it neither raises nor withdraws the question. Remanence reports a
  stalled input separately.
- **Only ever a question.** Recording never stops by itself.

### How the numbers were chosen

Each threshold came from the measurements, then got corrected where a real
master showed a problem:

- **8 seconds** is long enough to rule out a pause between songs and short enough
  that you hear about a stop quickly.
- **2.5 dB "near the floor"**: a stopped machine's band moves well under 1 dB
  from second to second. My first version took the 3rd-quietest tenth of each
  second with a tighter margin, and it **missed the end of RA-012 side A**, where
  the stopped machine sat 1.5–2 dB above the floor set at the tape's start.
  Switching to the middle tenth and widening the margin to 2.5 dB caught it.
- **3 dB running gap** is below the 4–8 dB measured on the Teac, leaving room for
  quieter tapes.
- **20th percentile** reflects the quiet parts of the tape (its gaps), when there
  are enough of them, without letting a single odd second decide.
- **60 seconds** keeps shorter gaps quiet when the floor wasn't heard.
- **5 seconds of listening** is more than a short pause between songs.

Bugs found along the way changed the design:

- Idle seconds after "Keep Recording" were dragging the running level down until a
  stopped machine looked normal. **Fix:** seconds known to be stopped are left out
  of the running level.
- The 60-second rule never fired, because the quiet stretch's own seconds dragged
  the percentile down to the floor. **Fix:** the current quiet stretch is left out
  when working out the running level.
- On a busy tape started before Record, the first long gap became the floor, and
  every later gap at that level asked after 8 seconds. **Fix:** only a floor heard
  while listening gets the 8-second rule.
- The wait before the tape started, and the first part of a stop found by the
  60-second rule, counted as running tape. Enough of them hid a real stop.
  **Fix:** quiet stretches that look stopped are left out of the running level.

## How it was tested

### Unit tests

`MachineStopDetectorTests` in `RemanenceCore/Tests/RemanenceCoreTests/RecordingTests.swift`
feeds made-up audio through the detector: quiet noise for a stopped machine, noise
at set levels around it (blank tape is 6 dB above), an 800 Hz tone for program, and
zeros for digital silence. Most run at 8 kHz in mono. "Heard" below means the
detector listened to the stopped machine before Record.

| Test | What it checks |
|---|---|
| `blankGapsOnATapeAreNeverFlagged` | Heard: long gaps of blank tape never ask |
| `theMachineStoppingIsNoticedQuickly` | Heard: a stop is noticed after about 8 seconds |
| `itWorksWithoutHearingTheMachineStoppedFirst` | Not heard: it waits about 60 seconds |
| `aDenseTapeStartedRollingStillFindsTheStop` | Not heard, no gaps: the stop is found after about 60 seconds |
| `aFirstGapOnADenseTapeIsNotAStop` | The first gap on a busy tape isn't taken for a stop |
| `aSecondGapOnADenseTapeIsNotAStop` | Nor are later gaps under a minute |
| `aSecondGapIsNotAStopAfterHearingTheTapePlay` | The same after listening to the tape playing |
| `listeningBeforeRecordTeachesTheStoppedFloor` | Heard: a long gap isn't a stop, and a stop asks in about 8 seconds |
| `onlyTheLastHalfMinuteOfListeningCounts` | Older, quieter listening is forgotten |
| `listeningToAPlayingTapeForgetsTheStoppedMachine` | A stop heard too long before Record doesn't count |
| `aShortPauseHeardWhileListeningIsNotTheStoppedFloor` | A 3-second pause heard while listening confirms nothing |
| `aStopAfterOnlyAnOpeningPauseTakesAMinute` | A pause after Record confirms nothing |
| `aFloorThatCreepsBelowTheHeardOneIsUnconfirmed` | A floor creeping down in small steps loses the 8-second rule |
| `aFloorWellBelowTheHeardOneIsUnconfirmed` | So does one that drops well below the heard level |
| `waitingAfterRecordDoesNotHideTheStop` | Heard: a long wait before the tape starts doesn't hide the stop |
| `waitingAfterRecordDoesNotHideAStopThatWasNeverHeard` | The same when not heard |
| `aStopFoundAfterAMinuteDoesNotHideTheNext` | A second stop is found too |
| `aPauseBeforeThereIsHistoryDoesNotHideTheStop` | A long pause early in a tape doesn't hide the stop |
| `anOpeningGapOnARollingTapeIsNotLearned` | A known cost: after an opening gap, a later 90-second gap asks, a 20-second one doesn't |
| `nothingIsSaidBeforeThereIsHistory` | No judgment before 30 seconds of running tape |
| `aTapeTooShortToJudgeIsLeftAlone` | A wait doesn't count towards those 30 seconds |
| `aTapeThatKeepsDippingToTheFloorIsLeftAlone` | A tape often as quiet as the floor is never asked about |
| `aThinMarginStillWorks` | Blank tape 3.5 dB up, stop drifted 2 dB up: asks within 40 seconds |
| `theReelsLooseEndSlappingDoesNotHideTheStop` | Slaps every 3 seconds don't hide the stop |
| `oddBlockSizesGiveTheSameAnswer` | Blocks that don't line up with the 100 ms readings |
| `itWorksAtNinetySixKilohertzInStereo` | 96 kHz stereo |
| `tapeOnOneInputOfAStereoPair` | Stereo with the tape on one input only |
| `digitalSilenceIsNotAStop` | Zeros never raise the question |
| `digitalSilenceDoesNotHideAStop` | Zeros partway through a stop don't restart the count |
| `digitalSilenceLeavesTheQuestionUp` | Zeros don't withdraw the question |
| `digitalSilenceNeverReachesTheRunningLevel` | Many zeros don't make a stop look like running tape |
| `itStaysStoppedThroughALongIdle` | The question stays up through a long idle |
| `itClearsWhenTheTapeRunsAgain` | The question clears when the tape runs |
| `aBumpDoesNotWithdrawTheQuestion` | A 2-second bump doesn't |
| `keepRecordingWaitsForTheTapeToRunAgain` | Keep Recording waits for the tape to run again |

All 499 tests in `RemanenceCore` pass, as counted by the test runner. That includes
the 36 in this suite, one of which is the gated check below, skipped unless it's
asked for. The app isn't covered by these tests.

### Against the real masters

A gated test, `realMasters`, runs every file in `masters/` through the detector as if
it were being recorded live, dismissing each question as "Keep Recording" would.
It prints the second at which it would have asked. It only reads the files. Quit the
app before pointing it at the real library.

```bash
REMANENCE_STOP_CHECK="$HOME/Music/Remanence" \
  swift test -c release --package-path RemanenceCore --filter MachineStopDetectorTests
```

Each file gets two passes:

- **cold:** nothing is heard before Record.
- **primed:** the file's first second is played six times as listening before
  Record, as if the app had just heard what the file opens with. If a file opens on
  running tape, that is what gets taken for the floor.

The two-pass version has been run on a synthetic scratch file only, not on
the real library (the app was still open). The file is
`$TMPDIR/remanence-scratch-ms/masters/stop-check-scratch.wav`: 5 s of quieter
noise, 60 s louder, then 30 s quieter again, left in place. **cold** asked
never; **primed** asked at 73 s, about 8 s into the last quiet part, as
expected. The real-library command above still needs the app quit before it is
run.

For the results below, I checked each reported second against where the machine
actually stopped, using each file's level second by second.

## Results

**These were measured on 2026-11-25 with the earlier rules and haven't been re-run.**
Under the current rules, with nothing heard before Record, those stops would now be
found after about a minute.

**Teac transfers (RA-008 to RA-015):**

- Every question came **2–10 seconds after the machine stopped**. This held for
  RA-013, RA-008 sides A and B, RA-009 A and B, RA-010 A, RA-011 and RA-012 A.
- **It never asked during a gap between recordings.**
- It would have caught four recordings that ran on past their tape:

  | Master | Asked at | Recording length |
  |---|---|---|
  | RA-009 side B | 959 s | 1043 s |
  | RA-010 side A | 2491 s | 2640 s |
  | RA-011 | 1288 s | 1673 s |
  | RA-012 side A | 1061 s | 1317 s |

  Nothing comes after any of these points, so they are true stops.
- RA-012 side A asked a second time at 1272 s, after a bump in its idle tail.
  That's still after the stop.
- RA-014 A and B, RA-015, RA-010 C and RA-012 B never asked. That's right:
  RA-015 never ran tape, and RA-014 B stopped only 6 seconds before its recording
  ended.

**Older imports:** it asked mid-tape in the old Logic Pro exports of RA-002 (at
1276 s and 2616 s) and RA-004 (at 123 s). Their gaps were processed down to no tape
noise, so these are the "tape no louder than a stopped machine" case under Limits.

## Limits

False questions:

- **A tape no louder than a stopped machine.** If blank tape is within 2.5 dB of
  the stopped machine in the midrange, gaps of 8 seconds or more ask (60 seconds if
  the stopped machine wasn't heard). That needs at least 30 seconds of louder tape,
  with shorter dips to the gap level making up less than about a fifth of the
  running level's history. This could happen with a very low-noise tape or noise
  reduction (Dolby or dbx).
- **Listening can hear the tape instead of the machine.** If the tape has been
  playing for more than 30 seconds before Record, and 5 or more of the last 30 were
  at its quietest level, that level is taken for the stopped machine. Later gaps at
  that level can ask after 8 seconds.
- **A gap over 60 seconds asks** when the floor wasn't heard and the gap is at it.
- **An opening gap isn't learned.** When the stopped machine wasn't heard, blank
  leader or a gap that the recording opens in, on a tape already rolling, is left
  out of the running level. So is a gap of 60 seconds or more that comes before
  there are 30 seconds of running tape. A later gap of a minute or more at that
  level can then ask.

Missed or late stops:

- **A minute, not 8 seconds,** whenever the stopped machine wasn't heard before
  Record.
- **Under 30 seconds of running tape is never judged.**
- **The floor only falls.** One moment quieter than the stopped machine, such as the
  Teac switched off, can lower it for the rest of the side. The stopped machine then
  sits above the floor, and nothing asks.
- **Stereo with the tape on one input** loses margin, because the two inputs are
  averaged. A 6 dB difference becomes about 4 dB.
- **A tape that dips to the floor often** (about a fifth of its length, in short
  dips) is never asked about.
- **Keep Recording during a blank tail** waits for the tape to run again, so if the
  reel then runs out, nothing asks.

Other:

- **Blank leader counts as stopped.** Leader has no oxide. That's fine, because a
  reel that has reached its leader has finished.
- **The figures come from one setup:** the Teac and the Scarlett at Teac 75% and
  Scarlett about 25%. The detector compares the input with its own floor, so it
  should cope with other settings, but that hasn't been measured.

## Live testing

The detector has still not run during a real recording. Everything above was checked
on recorded masters (with the earlier rules) and synthetic audio. The trial list is
under "Left for the live Teac trial" in
[machine-stop-plan.md](machine-stop-plan.md), with a short checklist in
[machine-stop-live-trial.md](machine-stop-live-trial.md).

## Files changed

| File | Change |
|---|---|
| `RemanenceCore/Sources/RemanenceCore/MachineStopDetector.swift` | New: the detector |
| `RemanenceCore/Sources/RemanenceCore/LevelAnalysis.swift` | `TapeEndDetector` removed |
| `RemanenceCore/Sources/RemanenceCore/AudioCapture.swift` | Feeds the detector, including while listening. The snapshot field is now `machineStopped`. |
| `Remanence/RecordModel.swift` | Asks when the machine stops, and withdraws the question if the tape runs again. A repeat reuses the notification identifier. |
| `RemanenceCore/Tests/RemanenceCoreTests/RecordingTests.swift` | `MachineStopDetectorTests` replace the old tests |
| `docs/native-app-plan.md` | A note on the change |
