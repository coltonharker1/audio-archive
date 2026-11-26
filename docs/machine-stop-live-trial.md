# Live trial: the machine-stop detector

The detector has not yet run during a real recording. This is the checklist for
that, taken from "Left for the live Teac trial" in
[machine-stop-plan.md](machine-stop-plan.md). The rules it tests are in
[machine-stop-detector.md](machine-stop-detector.md).

## Before you start

- [ ] **The real library must not be the launch library.** Everything goes into a
      scratch library.
- [ ] **Don't delete anything in `$TMPDIR`** during or after the trial, including
      the test recordings.
- [ ] Recording makes real files and captures real sound. Run
      `swift scripts/dev/micuse.swift` and don't record from an input another app
      is using.
- [ ] Build the app from this worktree:

      xcodegen generate --quiet
      xcodebuild -project Remanence.xcodeproj -scheme Remanence \
        -destination 'platform=macOS' -derivedDataPath .build/xcode build

- [ ] Quit any running Remanence normally. Otherwise `open` may only bring that one
      forward, with its own library.
- [ ] Launch from the worktree folder:

      open -g .build/xcode/Build/Products/Debug/Remanence.app --args \
        -siteURL http://127.0.0.1:9 -libraryPath "$TMPDIR/remanence-scratch-ms"

- [ ] **Check that the footer says "Scratch library"** before pressing Record. If it
      says "Local library", quit and don't record.

"Heard stopped" below means the machine sat stopped, with the recording screen open,
for at least 10 seconds before you pressed Record. The detector needs 5; the rest
is margin. This also applies between sides: after one side finishes, wait again.

Tapes need at least 30 seconds of sound above the stopped level before anything is
asked. Note the knob settings, and for each question note when it appeared compared
with what the machine was doing.

## The runs

### 1. One reel, usual start

Heard stopped, press Record, then Play. Record one Teac reel through run-out and
leave it running idle for a minute or two.

- [ ] Expect no question while the tape plays.
- [ ] Expect a question within about 10 seconds of the stop.

Result:

### 2. Record with the tape already rolling

Play for more than 30 seconds, then press Record. Let it run out.

- [ ] Expect no question in gaps under a minute.
- [ ] Expect a question about a minute after the stop.
- [ ] Note any gap that asks after about 8 seconds. That means listening took the
      tape's quiet level for the stopped machine.
- [ ] If Record landed in leader or a gap, note whether a later gap of a minute or
      more asks. That is a known cost.

Result:

### 3. A long wait before Play

Heard stopped, press Record, wait 2 minutes, play a few minutes, stop.

- [ ] Expect no question during the wait.
- [ ] Expect a question within about 10 seconds of the stop.

Result:

### 4. A mid-tape pause

Heard stopped. A few minutes in, pause for 20 seconds, then play on.

- [ ] Expect a question after about 8 seconds.
- [ ] Expect it to go away by itself a few seconds after the tape runs again.

Result:

### 5. Keep Recording

When asked, press **Keep Recording**, run the tape again, then let it run out.

- [ ] Expect no further question until the tape has run again for 3 seconds and then
      stopped.
- [ ] Expect it to ask about the second stop.

If you press Keep Recording during a blank tail and the reel then runs out, nothing
is expected to ask. That is a known limit.

Result:

### 6. Rewind and fast-forward while listening

The app doesn't show the level in the detector's band, so record a short take: a few
seconds stopped, some rewind, stopped, some fast-forward, stopped. Note the times.
Then print the band's level second by second (set `n` to the file's sample rate):

    ffmpeg -hide_banner -i "<the take>.caf" \
      -af highpass=f=500,lowpass=f=2000,asetnsamples=n=<sample_rate>,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=- \
      -f null -

These are plain one-second averages, so they only approximate what the detector
measures. For a stereo take they cover both inputs.

- [ ] Note the level when stopped, rewinding and fast-forwarding.
- [ ] If winding reads **below** stopped, doing it while listening or recording can
      set a floor that is too low, and the stop is then never asked about. If the
      difference is more than about 2.5 dB, try it: rewind on the recording screen,
      record a reel straight after, and see whether the stop is still found.

Result:

### 7. Stereo, 96 kHz, and dropouts

Record at least one full reel in stereo on the Scarlett at 96 kHz.

- [ ] Check the saved file, not just the device:

      find "$TMPDIR/remanence-scratch-ms/masters" -name '*.caf'
      ffprobe -hide_banner "<the file>"

- [ ] Expect 96000 Hz, 2 channels.
- [ ] Note the dropout count on every run. Any dropout is worth reporting.
- [ ] If the tape is on one input only, note it. That loses margin.

Result:

### 8. Notifications

During a bumpy run-out (move the reel or knock the machine now and then):

- [ ] Count the alert sounds and the notifications.
- [ ] A bump of a second or two should leave the question up, with no new alert.
- [ ] If it is withdrawn and asked again, expect a new sound, with the new
      notification replacing the old one rather than stacking.
- [ ] If no notifications appear at all, check they're allowed for Remanence in
      System Settings.

Result:

## Afterwards

- [ ] **Quit Remanence normally,** so the input's sample rate is restored.
- [ ] Leave the recordings where they are. Note the folder's size, so you can decide
      what to do with it later:

      du -sh "$TMPDIR/remanence-scratch-ms"

- [ ] With the app still quit, run the check against the real masters. It only reads
      them. Compare the cold and primed passes with the table in
      [machine-stop-detector.md](machine-stop-detector.md), which was measured with
      the earlier rules.

      REMANENCE_STOP_CHECK="$HOME/Music/Remanence" \
        swift test -c release --package-path RemanenceCore --filter MachineStopDetectorTests

- [ ] Write the real results into [machine-stop-detector.md](machine-stop-detector.md).
