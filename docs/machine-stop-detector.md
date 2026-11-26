# Telling a stopped machine from a silent tape

Written 2026-11-25. The code is on the `machine-stop` branch and isn't committed yet.

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
2. **Remember the floor.** The quietest second heard so far is the floor, and
   that's normally the machine stopped. The 30 seconds of listening before you
   press Record count too, because the machine is usually stopped then.
3. **Compare with the running tape.** The "running level" is the 20th percentile
   of the seconds heard so far: how quiet the tape gets while it's moving,
   including its gaps.
4. **Ask only when both are true:**
   - the band has sat at the floor (within 2.5 dB) for **8 seconds**, and
   - the running tape was clearly louder than the floor, by at least **3 dB**.

The second condition is what makes gaps harmless. A gap still has tape noise, so it
sits at the running level and not at the floor. If the quietest thing heard so far
was itself running tape, then nothing sits well above the floor, and nothing is said
until the machine really stops and the floor drops.

### Details added during testing

- **Reel slaps.** After a reel runs out, the loose end can slap the machine every
  few seconds as it turns. Each second is judged by its **middle tenth** (the
  median of ten 100 ms readings), so a slap doesn't make a stopped second look like
  running tape.
- **When the stopped machine was never heard.** If you start the tape before
  pressing Record, the first long gap might be quieter than anything heard before,
  which makes it the new floor. With nothing quieter to compare against, that
  stretch must last **60 seconds** instead of 8 before it asks.
- **Keep Recording.** Dismissing the question keeps it quiet until the tape has
  clearly run again for 3 seconds. Seconds known to be stopped are kept out of the
  running level, so a long idle doesn't start to look normal.
- **It clears itself.** If the tape starts moving again before you answer, the
  question goes away.
- **Digital silence** (a missing or stalled input) never sets the floor.
  Remanence reports a stalled input separately.
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
- **20th percentile** reflects the quiet parts of the tape (its gaps) without
  letting a single odd second decide.

Two bugs found along the way changed the design:

- Idle seconds after "Keep Recording" were dragging the running level down until a
  stopped machine looked normal. **Fix:** seconds known to be stopped are left out
  of the running level.
- The 60-second rule never fired, because the quiet stretch's own seconds dragged
  the percentile down to the floor. **Fix:** the current quiet stretch is left out
  when working out the running level.

## How it was tested

### Unit tests

`MachineStopDetectorTests` in `RemanenceCore/Tests/RemanenceCoreTests/RecordingTests.swift`
feeds made-up audio through the detector: quiet noise for a stopped machine,
slightly louder noise for blank tape, and an 800 Hz tone for program. The tests:

| Test | What it checks |
|---|---|
| `blankGapsOnATapeAreNeverFlagged` | Long gaps of blank tape never ask |
| `theMachineStoppingIsNoticedQuickly` | A stop is noticed after 7–9 seconds |
| `itWorksWithoutHearingTheMachineStoppedFirst` | Without a known floor, it waits about 60 seconds |
| `aFirstGapOnADenseTapeIsNotAStop` | The first gap on a busy tape isn't taken for a stop |
| `aTapeNoQuieterThanAStoppedMachineIsLeftAlone` | If running and stopped sound the same, it says nothing |
| `theReelsLooseEndSlappingDoesNotHideTheStop` | Slaps every 3 seconds don't hide the stop |
| `listeningBeforeRecordTeachesTheStoppedFloor` | Listening before Record sets the floor |
| `onlyTheLastHalfMinuteOfListeningCounts` | Older listening is forgotten |
| `nothingIsSaidBeforeThereIsHistory` | No judgment before 30 seconds of recording |
| `itStaysStoppedThroughALongIdle` | The question stays up through a long idle |
| `itClearsWhenTheTapeRunsAgain` | The question clears when the tape runs |
| `keepRecordingWaitsForTheTapeToRunAgain` | Keep Recording waits for the tape to run again |

All 429 tests in `RemanenceCore` pass, and the app builds.

### Against the real masters

A gated test, `realMasters`, runs every file in `masters/` through the detector as if
it were being recorded live, dismissing each question as "Keep Recording" would.
It prints the second at which it would have asked. It only reads the files.

```bash
REMANENCE_STOP_CHECK="$HOME/Music/Remanence" \
  swift test --package-path RemanenceCore --filter MachineStopDetectorTests
```

I checked each reported second against where the machine actually stopped,
using each file's level second by second.

## Results

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

**Older imports:** it asks mid-tape in the old Logic Pro exports of RA-002 (at
1276 s and 2616 s) and RA-004 (at 123 s). Their gaps were processed down to no tape
noise, so they really do look like a stopped machine. Live recordings from the Teac
always carry tape noise in their gaps, so these files don't stand for how the
detector will behave while recording.

## Limits

- **A tape no louder than a stopped machine.** If blank tape isn't at least 3 dB
  above the stopped machine in the midrange, the detector stays quiet rather than
  guess. This could happen with a very low-noise tape or noise reduction (Dolby or
  dbx).
- **Blank leader counts as stopped.** Leader has no oxide. That's fine, because a
  reel that has reached its leader has finished.
- **The figures come from one setup:** the Teac and the Scarlett at Teac 75% and
  Scarlett about 25%. The detector compares the input with its own floor, so it
  should cope with other settings, but that hasn't been measured.
- **Not yet tried live.** Everything above was checked on recorded masters and
  synthetic audio, not during a real recording.

## Files changed

| File | Change |
|---|---|
| `RemanenceCore/Sources/RemanenceCore/MachineStopDetector.swift` | New: the detector |
| `RemanenceCore/Sources/RemanenceCore/LevelAnalysis.swift` | `TapeEndDetector` removed |
| `RemanenceCore/Sources/RemanenceCore/AudioCapture.swift` | Feeds the detector, including while listening. The snapshot field is now `machineStopped`. |
| `Remanence/RecordModel.swift` | Asks when the machine stops, and withdraws the question if the tape runs again |
| `RemanenceCore/Tests/RemanenceCoreTests/RecordingTests.swift` | `MachineStopDetectorTests` replace the old tests |
| `docs/native-app-plan.md` | A note on the change |
