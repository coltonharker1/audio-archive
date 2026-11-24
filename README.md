# Remanence

A Mac app for archiving tapes: record them, transcribe them, read along, split them
into tracks, and publish them to [remanencearchive.com](https://www.remanencearchive.com).
It's built for one person's archive, so it skips the sandbox and the App Store.

## What it does

- **Record.** Capture reels, cassettes and microcassettes at up to 24-bit, 96 kHz
  through an audio interface, with a VU meter, a level check, side flips and markers.
  Recordings survive a crash.
- **Process.** Every recording is prepared, transcribed with Whisper and given a
  waveform in the background, even with the window closed. Claude writes summaries
  when asked.
- **Read and search.** Follow the transcript as the tape plays, fix misheard lines, and
  search every word on every tape.
- **Review.** Split a tape into tracks with markers, and trim it. The master is never
  cut.
- **Edit.** Set each track's level, speed and direction, trim its ends, zoom in to
  split precisely, join tracks and reorder them. Scrubbing sounds like rocking a reel.
- **Collections.** Group the reels from one box, with a write-up and photos, and
  publish them together.
- **Catalog numbers.** Each tape gets its RA number as it's recorded, so the box can be
  labelled straight away. The Catalog renumbers reels.
- **Publish.** Write each post in **Site Post**: title, description, photos, dates,
  and track text, with Claude's summaries alongside for reference. Push it to the site
  as an unpublished draft, then update it or refresh it from the site later.

Masters are read-only and are never changed.

## Building

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The app also
checks for these when it opens, and offers to download the Whisper models:

```bash
brew install xcodegen ffmpeg whisper-cpp
```

Summaries use [Claude Code](https://claude.com/claude-code), signed in on this Mac.

```bash
xcodegen generate
open Remanence.xcodeproj
```

Run the tests with `swift test --package-path RemanenceCore`, or through Xcode.

## Where things live

| Path | What it holds |
|---|---|
| `~/Music/Remanence/` | The library: the database, masters, processed audio, waveforms and photos |
| `~/Library/Application Support/Remanence/models/` | Whisper models |
| Keychain item `com.colton.remanence.site` | The site's sync API key |

## Code

| Path | What it is |
|---|---|
| `Remanence/` | The SwiftUI app |
| `RemanenceCore/` | Everything that can be tested without the interface |
| `project.yml` | Generates the Xcode project, which isn't checked in |
| `scripts/dev/` | Helpers for testing the running app |
| `docs/native-app-plan.md` | Decisions, status and what's next |
| `docs/recent-work.md` | What was built in November 2026, and how it fits together |
| `docs/collections/` | The collections design, with Codex's proposals and mockups |
| `docs/ideas.md` | Ideas not yet built |
| `docs/DESIGN.md` | History of the earlier Go version, which this replaced |
