# Remanence

A native macOS app for recording, transcribing, reviewing and publishing digitized
tapes. It replaced an earlier Go CLI and Next.js review app, which were removed from
this repo in Phase 7 and remain in git history.

**Picking this up? Read the "Current status" section of
[docs/native-app-plan.md](docs/native-app-plan.md) first.** It says exactly where
things stand and what to do next.

## Layout

| Path | What it is |
|---|---|
| `Remanence/` | The SwiftUI app |
| `RemanenceCore/` | Swift package with everything testable without UI |
| `project.yml` | Generates `Remanence.xcodeproj` and `Remanence/Info.plist` |
| `scripts/dev/` | Helpers for testing the running app without disturbing the user |
| `docs/native-app-plan.md` | Decisions, status, phases, lessons and site API changes |
| `docs/DESIGN.md` | History of the old Go app. Its paths and session notes are out of date. |

## Commands

```bash
xcodegen generate --quiet        # After adding or removing files. The project is gitignored.

# All tests, through Xcode
xcodebuild -project Remanence.xcodeproj -scheme Remanence -destination 'platform=macOS' \
  -derivedDataPath .build/xcode test

# Core tests only, faster
swift test --package-path RemanenceCore

# Checks against the real backup. Adding REMANENCE_LIBRARY also measures speed on
# the longest real tape. Quit the app first when pointing it at the real library.
REMANENCE_BACKUP="$HOME/Music/remanence-backup" \
  swift test --package-path RemanenceCore --filter RealBackup

# Launch in the background, without taking focus from the user
open -g .build/xcode/Build/Products/Debug/Remanence.app
```

## Where data lives

| Path | What it holds |
|---|---|
| `~/Music/Remanence/` | The library: `library.sqlite`, `masters/`, `processed/`, `peaks/` |
| `~/Library/Application Support/Remanence/models/` | Whisper models |
| `~/Music/remanence-backup/` | Verified backup of the site's audio. Only ever read it. |
| `~/code/me/web/remanence-archive` | The site's repo. Its secrets aren't in the clone. |

## Rules

**Protect the audio**
- Masters are read-only and irreplaceable. Nothing modifies them, and a recording
  must always save, whatever else goes wrong.
- Never restore or run the old Go app's `archive sync` from git history. It can
  overwrite live site entries.
- Deploying the site or changing its production database needs the user's
  confirmation each time.

**Testing the running app**
- The user may be working on this Mac. Never send system-wide keys or clicks. That
  once typed into their terminal. Check `lsappinfo front`, launch with `open -g`,
  and use the helpers in `scripts/dev/`.
- Don't record from a microphone another app is using, because it could capture a
  call. `scripts/dev/micuse.swift` shows what's in use.
- Playback and recording tests make or capture real sound, so say so first and keep
  them short. Remove test recordings afterward.
- Quit the app normally rather than killing it. A killed app leaves its job folders
  in `$TMPDIR` until a launch more than a day later removes them. Scratch libraries
  (`-libraryPath`) live in `$TMPDIR/remanence-scratch`.
- Commit only when asked, on the `native-app` branch.

**SwiftUI traps already hit**
- Don't put `.fixedSize(horizontal: false, vertical: true)` on text outside a
  `ScrollView`. AppKit measures minimum size at near-zero width, so the text reports
  huge heights and pushes the whole window off-screen.
- Use `.fixedSize()` on labels and buttons in rows that can get narrow, or they stack
  letter by letter.
- Check layouts at the real window size, 900 by 692.
- Reading `player.preciseTime` alone doesn't redraw after a seek while paused. Also
  read `player.currentTime` so Observation fires.

**Audio traps already hit**
- Capture uses an input-only HAL audio unit, not `AVAudioEngine`. The engine stops
  itself when pointed at an input-only device, and it keeps the first sample rate it
  sees for the life of the app, quietly saving 96 kHz audio at 48 kHz.
- Check the saved file's rate with `ffprobe`. The device's rate alone proves nothing.
- Don't change a device's sample rate while another app is using it.
- Check `isRunning` and whether buffers are really arriving. A stalled input looks
  just like silence on the meter.
- Killing the app skips restoring the input's sample rate. Quit normally, or put the
  rate back afterward.
- Prefer real hardware over virtual inputs. Teams installs a silent one.
- Run tools with `HOME`, `USER` and `PATH` set. `claude` reports "Not logged in"
  without `USER`, and exits 0 when it does, so check `is_error`.
- GRDB refuses writes from cancelled tasks, so save results from a detached task.
