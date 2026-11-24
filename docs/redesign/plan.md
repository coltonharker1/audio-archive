# Redesign implementation plan

How to build the approved mocks in `docs/redesign/` (01-shelf through 07-push-publish)
into the app, in 15 small phases. Written 2026-11-24 from the brief, the proposal, the
seven mocks, `CLAUDE.md`, the docs, and the code in `Remanence/` and `RemanenceCore/`.

This is a UI and flow redesign. No feature, data format, site route or push rule changes.
Where a mock shows something the app can't do today, section 5 says whether it's built
as pure UI over an existing function or left as an open question (section 8).

**Not verified while planning:** the core tests weren't run in this session (the command
needed an approval that wasn't available), so the baseline of 329 tests comes from
`docs/recent-work.md`. Phase 0 confirms it before anything changes.

**Revised 2026-11-24** after `docs/redesign/plan-review.md`. Each of its claims was
checked against the code and the mocks before it was acted on. Section 10 lists what
changed, the two places the review was slightly off, and the one suggestion not taken
whole.

## Contents

1. Hard rules for every phase
2. What changes, screen by screen
3. Commands and the standard checks
4. Shared design decisions
5. Where the mocks imply new behaviour
6. Phase overview
7. The phases
8. Open UI questions
9. Risks
10. Review response

---

## 1. Hard rules for every phase

These hold at the end of every phase. A phase that can't keep one stops and asks.

| Rule | What it means for this work |
|---|---|
| Masters are never changed | No phase touches `Recording.swift`, `CaptureFile.swift`, `AudioCapture.swift`, `Sides.swift`, `Markers.swift`, `Appending.swift`, `TrackAdjustments.swift` or anything that writes under `masters/`. Views keep calling the same `Library` functions. A recording must still always save. |
| Pushes arrive as unpublished drafts | `Push.swift`, `SiteSync.swift`, `CollectionSync.swift`, `Catalog.swift` and `SiteClient.swift` are not edited. Renamed buttons call the same `PushModel` functions. "Create unpublished draft" is `PushModel.start`. Publish stays a separate, explicit click. |
| Site edits are checked against the site's clock | `expectedUpdatedAt` handling stays as it is. Whatever error text a screen shows today, it still shows: Site Post's `syncFailure` and `failure`, Catalog's `failure` from `renumber`, and the collection's `collectionFailure`. One case is quiet on purpose and stays quiet: `CollectionSync.pushCollection` absorbs the first `SiteError.changedOnSite`, fetches the site's new clock and sends the local collection again, so that conflict never appears in the collection's site sheet. Only a second failure, or a conflict on delete, does. No phase edits that file to change this. |
| Never run the app against the live site | Every manual check launches with the site pointed away (section 3.4). Nobody clicks Push, Update, Publish, Unpublish, Delete from Site, Bring In or Apply in a build that can reach `remanencearchive.com`. Push logic is exercised only through `FakeSite` in `PushTests.swift`. |
| No schema change that could lose data | No new migration in `AppDatabase.swift`. New UI state never goes in `library.sqlite`. The last position is saved in `UserDefaults`. Staged catalog changes live in memory only, until Apply, Revert or quit (Q13), so a stale renumber is never offered on the next launch. |
| SwiftUI traps in `CLAUDE.md` | No `.fixedSize(horizontal: false, vertical: true)` on text outside a `ScrollView`. `.fixedSize()` on labels and buttons in rows that can get narrow. Check at 900 by 692. Read `player.currentTime` alongside `player.preciseTime`. |
| Testing rules in `CLAUDE.md` | Launch with `open -g`. No system-wide keys or clicks; use `scripts/dev/app.swift`. Check `lsappinfo front`. No recording from a microphone another app is using (`scripts/dev/micuse.swift`). Say so before any test that plays or captures sound, keep it short, and remove test recordings. |
| Commits | Only when asked. `CLAUDE.md` names the `native-app` branch, and this work is on `redesign`. Confirm the branch with the owner before the first commit. |

---

## 2. What changes, screen by screen

| Area | Today (code) | Approved mock |
|---|---|---|
| Sidebar | `LibraryView`: four `ShelfFilter` rows with counts, then collections | Recording, then Library (Shelf, Catalog, Site Posts), then Collections, with Setup at the foot |
| Toolbar | Catalog, Site Posts and Record a Tape buttons, shown only on the shelf | Breadcrumb and the search field. Those three become sidebar destinations |
| Footer | None | A status line: "Local library" and a per-screen note (background work, key hints, counts) |
| Shelf | `ShelfView`: drawn tape boxes on boards, plus `TapePanel` along the bottom with four equal buttons | "Last opened" hero with Resume, filter tabs with counts, a table of Number, Reel, Collection, Length, Status |
| Recording | `RecordView`: setup column that hides while recording, meter stage, buttons under it | Meter panel with clock and input history on the left; tape label, capture settings, machine note and collection on the right; after Stop, the next steps appear in place |
| Review / Edit / Read Along / Site Post | Four separate screens, each with its own back button and header. Read Along has buttons to the other three | One tape header and four tabs. Review has "Edit selected track". Edit has "Return to Side A" |
| Review | Overview, zoomed waveform, controls, marker controls, key hints, tracks in a toggled inspector | Same parts, with the track list in a fixed right column and key hints in the footer |
| Edit | One card per track, each with its own level, speed, direction controls and its own zoom | Compact track rows, one close-up for the selected track, and one inspector on the right |
| Site Post | Long form: site section, details, description, photos, tracks, push section at the bottom | Writing on the left; site status and its one next action on the right. "Looks Good" becomes "Approve for push" |
| Collection | An always-editable form with the site panel inline | A page to read: write-up beside the contact sheet, reels table below. Editing, photos and the site draft open from buttons |
| Catalog | `CatalogView` sheet from a toolbar "#" button | A sidebar destination with Current and Proposed columns and a Pending changes column |
| Site Posts | `SitePostsView` sheet | A sidebar destination (the mock only sketches its table in an unused dialog; see Q1) |

---

## 3. Commands and the standard checks

### 3.1 Build

```bash
xcodegen generate --quiet        # after adding or removing files
xcodebuild -project Remanence.xcodeproj -scheme Remanence -destination 'platform=macOS' \
  -derivedDataPath .build/xcode build
```

Passes when it ends with `BUILD SUCCEEDED` and no new warnings in files the phase touched.

### 3.2 Core tests

```bash
swift test --package-path RemanenceCore
```

Passes when every test passes and the count is 329 plus the tests added so far. A phase
never deletes or weakens an existing test. If a type moves into the core, its old tests
move with it unchanged.

329 is the number of `@Test` functions. Some are skipped without `ffmpeg`, without
`REMANENCE_NETWORK_TESTS=1`, or without `REMANENCE_LIBRARY`, so compare counts only
between runs on the same machine with the same environment.

### 3.3 All tests through Xcode (run at the end of phases 2, 3, 8 and 14)

```bash
xcodebuild -project Remanence.xcodeproj -scheme Remanence -destination 'platform=macOS' \
  -derivedDataPath .build/xcode test
```

The scheme in `project.yml` runs only `RemanenceCoreTests`, so this is the same tests
as 3.2 plus a build of the app target. It's still run at those phases as a check that
the app and the package build together. It does not test navigation; there is no app
test bundle, and this plan doesn't add one. Navigation is checked by hand.

### 3.4 Launching for a manual check

```bash
lsappinfo front                                  # see what the owner is using first
open -g .build/xcode/Build/Products/Debug/Remanence.app --args \
  -siteURL http://127.0.0.1:9 \
  -libraryPath "$TMPDIR/remanence-scratch"       # from Phase 0 onward
```

- `-siteURL` is read by `PushModel.siteURL` from `UserDefaults`, and a launch argument
  sets it for that run only. It must be on **every** manual launch. Without it, opening
  Recording, Catalog or Site Posts reads the live site when a key is in the Keychain.
- `-libraryPath` is the scratch library added in Phase 0. Use it for anything that
  writes (reordering, renaming, staging, recording). States that only the real library
  has (pushed, published) can be looked at there with `-siteURL` set, without clicking
  anything that writes.
- Quit normally afterward, never with `kill`, so an input's sample rate is restored.

### 3.5 Layout check at 900 by 692

1. Find the window with `swift scripts/dev/winall.swift` and confirm its bounds read
   900 by 692. If not, resize that window only (an Accessibility call addressed to the
   Remanence process). Never post global input.
2. Capture it with `screencapture -l <window id>`, which works on another Space.
3. With the sidebar open and any right column open, check all of these:
   - the window hasn't grown or moved off-screen
   - no label or button is stacked letter by letter or clipped
   - the screen's main action is visible without scrolling
   - numbers and timecodes line up in their columns
   - the footer is one line
4. Repeat at the minimum size, 860 by 640, and once at 1440 by 900 beside the mock.

Each phase's acceptance list names the screens and states to capture.

---

## 4. Shared design decisions

These are settled here so later phases don't each invent their own.

### 4.1 Colour and type (from the mocks' CSS)

| Token | Value | Used for |
|---|---|---|
| paper | `#faf5ee` | Window and page background |
| ink | `#211d19` | Text |
| muted | `#696156` | Secondary text, table headers, small cap labels ("Tape label", "Pending changes") |
| line | `#dcd4c8` | Rules and row dividers |
| rail | `#ede7dd`, selected row `#dbd3c6` | Sidebar |
| bar / footer | `#f4eee5` / `#f2ece2` | Toolbar tint and status line |
| panel | `#eae2d4` (hero), `#eee7dc` (inset), `#efe7da` (picked row) | Grouped areas |
| field | `#fdfaf5`, border `#cfc6ba` | Text fields |
| button | `#fcf9f3`, border `#c9c0b4`; primary `#2c2923` with `#fffaf0` text | Buttons |
| scope | `#eae5d9`, border `#cfc7b9`; waveform `#716e5d` | Waveform areas |
| rust | `#914d37` (needle `#9d4e35`, eyebrow `#81533d`) | Recording and edit position, attention, page eyebrows |
| status dots | published `#61775d`, draft `#9e8054`, working `#a36245`, idle `#88877a` | The 7-point dot in a status badge |
| meter | panel `#292e29`, text `#f4efdc`, recording dot `#de886c` | The dark meter panel on the record screen only |

- Serif: Iowan Old Style, Palatino Linotype, Palatino, Georgia, then the generic
  serif. This is the stack in every mock and in `proposal.md`. The helper tries each
  name in that order and uses the first that resolves. Used for titles, track names,
  captions and the write-up.
- Two small-label styles, same font (monospaced, 10 pt, uppercase, tracked), different
  colour. **Eyebrow** is rust `#81533d` and sits above a page or hero title. **Cap**
  is muted and is used for table headers and labels such as "Tape label" and "Pending
  changes". Don't use one style for both.
- Monospaced with tabular digits: RA numbers and timecodes.
- System sans: controls.
- Status badge text is ink. Only the dot is coloured. Draft gold on paper is about
  3.4 to 1, too low for text.
- The app stays forced to light mode.

**Old `Theme` names.** `Theme.card` and `Theme.board` are used 34 times across ten
files. Phase 1 keeps every old name as an alias so no view has to change meaning:

| Old name | Becomes |
|---|---|
| `paper`, `ink` | the same tokens |
| `inkMuted` | muted |
| `card` | inset panel `#eee7dc` |
| `board` | hero panel `#eae2d4` |
| `accent`, `attention` | rust `#914d37` |
| `good` | published green `#61775d` |
| `display(_:)` | the serif helper at that size |

**Which time format goes where.**

| Format | Example | Used for |
|---|---|---|
| `clock` (as today) | `0:42`, `1:02:09` | Lengths, track starts and durations, rulers, "0:42 / 1:42" |
| `precise`, tenths (as today) | `0:34.0` | Review's marker times |
| `hundredths` (new) | `0:00.48` | Edit's Trim start and Trim end |
| `timecode` (new) | `00:01:18` | The record screen's large clock only |
| `long` (as today) | `12 min` | Where it's used today |

### 4.2 Sizes at the real window

The mocks are drawn at 1440 by 900. At 900 by 692 the detail area is about 680 points
wide, so the same sizes don't fit. Two size classes, chosen from the detail area's width:

| | Regular (detail 980 or wider) | Compact (narrower, including 900 by 692) |
|---|---|---|
| Page title | 49 pt | 32 pt, one line, full title in a tooltip |
| Hero title (beside the picture) | 35 pt | 26 pt |
| Section title | 27 pt | 21 pt |
| Track and reel names | 19 pt | 16 pt |
| Page padding | 3.35% of the window width, held between 25 and 49, as the mock's `clamp` | the same rule; about 30 at 900 wide |
| Right column | 282 fixed | 230, and it can be hidden (Q5) |
| Shelf hero height | 212 | 150 |

### 4.3 Structure

- Keep `NavigationSplitView`, the native toolbar and `.searchable`. The breadcrumb goes
  in the toolbar's leading area. No custom title bar.
- The footer is one view under the split view, fed by a small per-screen value on
  `AppModel`. Each screen's note is the mock's sentence, set in the phase that builds
  the screen:

  | Screen | Footer note | Phase |
  |---|---|---|
  | Shelf | "Background activity · Listening… RA-028" while work is running (the mock says "Transcribing"; Q14 keeps "Listening…"). With several tapes working, today's `pipelineSummary`. Otherwise empty. | 4 |
  | Recording | "RA-019 · Side A" | 10 |
  | Review | Key hints, shortened to fit | 6 |
  | Edit | "Edits apply to playback and site copies · Master preserved" | 7 |
  | Site Post | "RA-019 · 3 tracks in site order" | 11 |
  | Collection | "6 reels · 2 published reels · Collection draft on site" | 12 |
  | Catalog | "2 proposed changes · Awaiting confirmation" | 13 |
  | Anything else | `pipelineSummary` | 2 |
- Keep the existing `Route` cases `.review`, `.edit`, `.readAlong` and `.post`. They
  become the four tabs. `AppDelegate`'s key and scroll handling tests `route == .review`
  and `route == .edit`, so keeping the cases keeps the keys working.
- A tab that isn't showing is removed from the view tree, not hidden. `SitePostView`,
  `EditView`, `CollectionView` and Read Along's notes all save in `onDisappear`.
- Controls that the mocks leave out but the app has today stay reachable. Each phase
  lists them under "Must still work".

---

## 5. Where the mocks imply new behaviour

| # | In the mock | Decision |
|---|---|---|
| N1 | "Last opened", "Resume Side A at 0:42" | Built as UI state: the last tape, tab, side, playhead and zoom, saved in `UserDefaults`. No database change. Details in Q4. |
| N2 | "Edit selected track" and "Return to Side A" | Built as navigation between two existing screens, carrying the playhead. No data changes. |
| N3 | "Import audio…" button | Built: an open panel that feeds the existing `AppModel.add`. Import Backup stays in the File menu and the empty shelf. |
| N4 | Catalog and Site Posts as sidebar destinations | Built: the same views, hosted in the detail area. Staging rules unchanged. |
| N5 | Setup at the foot of the sidebar | Built: shows the existing `SetupView` on demand. What else belongs there is Q15. |
| N6 | "Append to another track…" | Built: a menu of target tracks that calls the existing `EditModel.append`, with the existing confirmation and the text `EditView.appendMessage` gives today, not the longer preview in `ideas.md`. |
| N7 | "Add reels…" on a collection | Built: a picker that calls the existing `setCollection`. Moving a reel out of another collection is Q12. |
| N8 | "Save" on Site Post | Built as "save now". Autosave stays, or typed text could be lost. |
| N9 | "Approve for push" | A rename of "Looks Good". Same `approvedAt`. Taking approval back is Q8. |
| N10 | "24-bit / 96 kHz" on the meter | Display only: 24-bit is what `CaptureFile` always writes, and the rate comes from the capture snapshot. Never a hard-coded rate. |
| N11 | Trim start and end as numbers in Edit | Shown read-only. Typing a trim would be new behaviour (Q10). |
| N12 | Status words: Published, Draft on site, Local only, Ready to review, Transcribing | Built as one mapping from fields the app already has. Wording is Q14. |
| N13 | Shelf rows with no bottom panel | The panel's jobs move (Phase 3 and 4). Quick play from the shelf is Q3. |
| N14 | Marker flags labelled with the track number | Display only. The time still shows while dragging. |
| N15 | "Undo" button in Review | Calls the existing `ReviewModel.undo`. Edit gets no undo; that's in `ideas.md` and out of scope. |
| N16 | Read Along drawn as a dialog | Not settled by the mocks (Q2). Planned as a full tab. |
| — | Sample titles, numbers, timings, "Peak −8.4 dBFS" | Illustrative, as the proposal says. Nothing is built from them. |

Not in the mocks and **not** built: marker key while recording, Listen Later flags,
dropout times, alternate takes, photos while recording, undo in Edit, preview links.
They're in `docs/ideas.md`.

---

## 6. Phase overview

| # | Phase | Mocks | New core tests |
|---|---|---|---|
| 0 | Baseline and a scratch library | — | — |
| 1 | Design language | all | time text |
| 2 | Navigation shell | all (rail, bar, footer) | shelf filters |
| 3 | Tape workspace: one header, four tabs | 03, 04, 07 | where Back goes |
| 4 | Shelf list | 01 | shelf status |
| 5 | Shelf memory and Resume | 01 | work position |
| 6 | Review layout | 03 | — |
| 7 | Edit layout | 04 | — |
| 8 | Review to Edit and back | 03, 04 | track handoff |
| 9 | Read Along tab | 03 (dialog sketch) | — |
| 10 | Recording | 02 | — |
| 11 | Site Post | 07 | site state wording |
| 12 | Collection | 05 | collection footer counts |
| 13 | Catalog | 06 | catalog staging |
| 14 | Site Posts, search, setup, and the final pass | 01 (dialog sketch) | — |

**Build them in number order, one at a time.** Every phase leaves a working app. The
phases are not independent enough to run side by side:

| Phase | Needs first | Why |
|---|---|---|
| 1, 2, 3 | the one before | Each builds on the last. |
| 4 | 3 | Side management has moved out of the shelf panel. |
| 5 | 4 | The hero sits above the table. Also edits `ShelfView.swift` and `AppModel.swift`. |
| 6 | 5 | Both edit `ReviewModel.swift`. |
| 7 | 3 | Side options must hold single-side rename before Edit's side heading goes. |
| 8 | 5, 6 and 7 | The return trip uses Phase 5's zoom-restore path, and both buttons live in the new layouts. |
| 9 | 3 | Rewrites `ReadAlongView.swift` and must keep the approve toggle parked there. |
| 10 | 2 | Only `RecordView.swift`. Could move earlier, but stays in order. |
| 11 | 9 | Also edits `ReadAlongView.swift`, to remove the parked toggle once Site Post can withdraw approval. |
| 12 | 4 | Extends `ShelfStatus.swift`, which Phase 4 creates. |
| 13 | 2 | Needs the Catalog route. Also edits `AppModel.swift`. |
| 14 | all | Final pass. |

Files several phases share, so never open two of these phases at once: `AppModel.swift`
(2, 3, 4, 5, 8, 13), `ReviewModel.swift` (5, 6), `ShelfView.swift` (2, 4, 5),
`ReadAlongView.swift` (3, 9, 11), `ShelfStatus.swift` (4, 12).

---

## 7. The phases

### Phase 0. Baseline and a scratch library

**Goal.** Know the starting point, and make manual checks unable to touch the real
library or the live site.

**Mocks.** None. No visible change with normal launches.

**Files.**
- `Remanence/AppModel.swift`: `paths` comes from a launch argument `-libraryPath` when
  one is given, otherwise `LibraryPaths.standard` exactly as now. Read it from the
  argument domain only, so it can never be saved as a default.
- `Remanence/PushModel.swift`: no change; `siteURL` already has its override.
- No core changes.

**Must still work.** A normal launch opens `~/Music/Remanence` and behaves identically.

**Tests.** None new. Record the real baseline count here.

**Acceptance.**
- Build: 3.1 succeeds.
- Tests: 3.2 passes; write down the count (expected 329).
- Launch per 3.4 with a new scratch path: an empty shelf appears, a `library.sqlite` is
  created under the scratch path, and `~/Music/Remanence/library.sqlite`'s modification
  time is unchanged.
- Seed the scratch library with three short generated tones (two files in one folder,
  one alone) and confirm they appear. Don't drag onto the Dock icon; that takes focus.
  Use the same code path without the drag: `open -g -a <the built app> <files>`
  while the scratch instance is the one running, which arrives at
  `application(_:open:)`, or drop onto the scratch window with `scripts/dev/app.swift`.
- Layout: capture "before" pictures at 900 by 692 into the scratchpad. Three local
  tones can show: the shelf and its panel, Review, Edit, Read Along (once they've been
  listened to, or its "still listening" state), Site Post before any push, a collection
  made in the scratch library, the Catalog and Site Posts sheets (Site Posts showing its
  failure text), and record setup. They can't show Published, Draft on site, a pushed
  collection or a real transcript. Capture those from the real library with `-siteURL`
  set, looking only.

This override is a developer aid beyond the mocks. If the owner would rather not have
it, skip the code change and do all write-type checks only through tests (see Q22).

---

### Phase 1. Design language

**Goal.** The palette, type and small parts from the mocks, applied app-wide, with no
change to layout or flow.

**Mocks.** All seven (shared CSS).

**Files.**
- Add `Remanence/DesignSystem.swift`: move `Theme` out of `RemanenceApp.swift` and set
  it to the tokens in 4.1. Keep `card`, `board`, `inkMuted`, `accent`, `good`,
  `attention` and `display(_:)` as aliases, mapped as 4.1's table says, so every
  existing call compiles and keeps its meaning. Add the font helpers (serif with the
  full fallback stack from 4.1, eyebrow, cap, mono number), the size class from 4.2, and
  small views used later: eyebrow label, cap label, page
  header (eyebrow, title, subtitle, actions), status badge with dot, hairline rule,
  key-value row, track row (number, serif name, small line, duration), primary and
  standard button styles, field style, scope background.
- `Remanence/RemanenceApp.swift`: `Theme` removed from here. `TimeLabel` stays, with
  `clock` and `long` forwarding to the core.
- `Remanence/ReviewView.swift`: `ReviewTime` stays where it is, with `precise`
  forwarding to the core. Nothing else in this file changes in this phase, so the
  review screen keeps compiling and looking the same.
- Add `RemanenceCore/Sources/RemanenceCore/TimeText.swift`: the existing `clock`,
  `long` and `ReviewTime.precise` formats moved in unchanged, plus `timecode`
  (`00:01:18`) and `hundredths` (`0:00.48`) for the mocks. 4.1 says which screen uses
  which.
- Add `RemanenceCore/Tests/RemanenceCoreTests/TimeTextTests.swift`.
- Existing views: only colour and font references change where a token was renamed.

**Must still work.** Everything. `Theme.accent`, `good` and `attention` keep their
meaning (accent and attention move to the rust family, good to the published green).
`card` and `board` still draw a panel that's visibly different from the paper.
The VU meter face, peak light and waveform colours stay readable on the new paper.

**Tests.** `TimeTextTests`: under and over an hour, negative and non-finite input, the
rounding case already noted in `ReviewTime` (1234.0 must not read as 20:33.9), timecode
past 99 minutes, hundredths rounding.

**Acceptance.**
- Build: 3.1 succeeds after `xcodegen`.
- Tests: 3.2, baseline plus `TimeTextTests`.
- Layout at 900 by 692: shelf, Review, Edit, Read Along, Site Post, collection, record
  setup. Same layouts as the "before" pictures, new colours and serif. The serif renders
  as Iowan Old Style (compare a title against the mock at 1440 by 900).
- Text contrast: muted on paper is at least 4.5 to 1 (it's about 5.6). No text is set
  in a status-dot colour.

---

### Phase 2. Navigation shell

**Goal.** The mock's sidebar, breadcrumb and footer. Every destination is reachable from
the sidebar. Screen contents are unchanged in this phase.

**Mocks.** The rail, bar and footer in all seven.

**Files.**
- `Remanence/AppModel.swift`:
  - `SidebarItem` becomes recording, shelf, catalog, sitePosts, collection(id), setup.
  - `Route` gains `.catalog`, `.sitePosts`, `.setup`.
  - `filter` stays as the shelf's tab state. Its `didSet` jump to the shelf stays.
  - Add a footer note value that each screen can set.
  - Selecting Recording calls the existing `openRecording()`, keeping its "a push is
    running" refusal.
- Move `ShelfFilter` to `RemanenceCore/Sources/RemanenceCore/ShelfFilter.swift` with
  the same `includes` rules and a `label` for the tabs ("All reels", "Ready to review",
  "In progress", "On the site").
- Add `RemanenceCore/Tests/RemanenceCoreTests/ShelfFilterTests.swift`.
- `Remanence/LibraryView.swift`: new sidebar list (wordmark, items, Collections,
  "New collection…", Setup); toolbar reduced to the breadcrumb and search; the two
  sheets removed; detail switch gains the three new routes.
- Add `Remanence/StatusBar.swift`: the footer. Left: "Local library" (or "Scratch
  library" when `-libraryPath` is set). Right: the screen's note, defaulting to
  `pipelineSummary`.
- `Remanence/ShelfView.swift`: a plain tab strip for the four filters with their counts,
  above the existing shelf. The table comes in Phase 4.
- `Remanence/CatalogView.swift`, `Remanence/SitePostsView.swift`: drop the fixed sheet
  frame and the Done button so they fill the detail area. Nothing else yet.
- `Remanence/RemanenceApp.swift`: `RootView` shows `SetupView` for `.setup` as well as
  when tools are missing.

**Must still work.**
- Collections in the sidebar: drop a tape on one to add it; right-click to delete, with
  the same confirmation; New Collection alert.
- ⌘R, ⌘⇧I, ⌘F, and search taking over the detail area and returning to where it was.
- File and folder drop on the window and on the Dock icon, with the drop overlay.
- The import banner.
- Leaving the record screen while recording does not stop the recording
  (`RecordModel.close()` refuses). The sidebar's Recording row shows a recording dot
  while `recordModel.isRecording`.
- A deleted tape or collection still drops its selection and returns to the shelf.
- The menu bar item and its summary.

**Tests.** `ShelfFilterTests`: each filter against idle, waiting, working, failed,
approved, pushed tapes. Approved and unpushed tapes are in "All reels" only, as today.

**Acceptance.**
- Build: 3.1 after `xcodegen`. Tests: 3.2 and 3.3.
- Layout at 900 by 692: sidebar with 0, 1 and 8 collections (long names truncate, none
  wrap); each of Shelf, Catalog, Site Posts, a collection, Recording and Setup shows in
  the detail area with the right breadcrumb and sidebar highlight; footer is one line.
- Recording survives navigation. A level check can't prove this: it isn't
  `isRecording`, so leaving runs `close()`, which cancels the check and stops the
  input, and coming back starts a fresh one. The check that matches the code is a real
  recording. Only with the owner's go-ahead: run `scripts/dev/micuse.swift` first and
  stop if any app is using the input. Say that it records. With the scratch library,
  start a recording, open Shelf, Catalog, Site Posts, a collection and Setup in turn,
  and come back. The same take is still running, its clock never restarted, and the
  sidebar showed the recording dot throughout. Stop, remove the test tape, quit
  normally. If there's no go-ahead, leave this box unticked and carry it to Phase 10's
  live check. Don't substitute a level check; that opens the input too.
- Site Posts with the site pointed away shows its failure text, not a spinner forever.

---

### Phase 3. Tape workspace: one header, four tabs

**Goal.** Review, Edit, Read Along and Site Post share one header and a tab row. Moving
between them keeps the tape and where you came from.

**Mocks.** The header and tabs of 03, 04 and 07.

**Files.**
- Add `Remanence/TapeWorkspaceView.swift`:
  - Header: eyebrow (RA number and medium), title, subtitle ("From the collection …",
    side, length), and the four tabs.
  - A side switcher in the subtitle when the tape has more than one recording. It
    replaces the "Recording" and "Track" pickers and calls `model.choose(itemAt:)`.
    Imported tapes show file names, as `ShelfTape.Item.name` gives them.
  - "Side options ▾", a menu built as its own small view. In this phase it sits at the
    end of the header's subtitle line. Phase 6 moves it to where the mock draws it, the
    foot of Review's track column. It holds:
    - Rename Side… and Delete Side… for a tape with two or more recordings, moved from
      `TapePanel` with the same alerts, the same wording, and the same rule (only when
      the tape isn't on the site).
    - Rename Side… for a tape with **one** recording that has a side name. `TapePanel`
      doesn't offer this today; the only way is double-clicking Edit's side heading
      (`SideHeader`), under the same not-on-the-site rule. Phase 7 removes that
      heading, so the command has to be here first. It calls the same rename function
      `SideHeader` calls. Delete Side… is not offered for a single recording, as today.
  - Hosts the existing four views as tab content.
- `Remanence/AppModel.swift`: add `switchTab(_:)`, which changes `route` among the four
  without resetting where Back goes. Today `openReview`, `openEdit` and `openPost` each
  overwrite `routeBeforeReadAlong`, which would lose "Results". Add an origin of shelf,
  collection or search results for the breadcrumb's first crumb.
- Add `RemanenceCore/Sources/RemanenceCore/TapeOrigin.swift`: the origin as a small
  enum, and one function saying where Back goes from a tab (results only while the
  search text is still there, otherwise the collection or the shelf). The app has no
  test target, so this is what pins the bug above.
- Add `RemanenceCore/Tests/RemanenceCoreTests/TapeOriginTests.swift`.
- `Remanence/ReviewView.swift`, `EditView.swift`, `ReadAlongView.swift`,
  `SitePostView.swift`: remove each one's own back button, title and cross-links. Bodies
  otherwise unchanged. Edit keeps its locked-on-site line.
- `Remanence/LibraryView.swift`: the four routes show `TapeWorkspaceView`.

**Must still work.**
- Each tab's keys: Review's full set, Edit's set, Space and arrows elsewhere, and typing
  in a field never triggering them.
- ⌘Z and ⌘⇧Z in Review only.
- Sideways swipe panning in Review and Edit.
- Site Post saves when you leave its tab; Edit flushes level changes and stops its
  player when you leave its tab; Read Along saves its notes.
- Opening a search result lands on Read Along at the moment and plays; Back returns to
  the results while the search text is there.
- "Looks Good / Approved" on Read Along still toggles (moved into the tab body for now;
  Phase 11 gives it its final home).
- Review's and Read Along's inspectors and their toolbar toggles.
- A tape still being processed opens, with its activity line visible somewhere in the
  header (today the shelf panel shows it, with Try Again on failure; keep both).

**Tests.** `TapeOriginTests`: opened from the shelf, a collection and search results;
switching through all four tabs keeps the origin; Back from a search result goes to
results while the search text is there and to the shelf once it's cleared; a deleted
collection falls back to the shelf.

**Acceptance.**
- Build: 3.1 after `xcodegen`. Tests: 3.2 and 3.3.
- Layout at 900 by 692, for a one-recording tape and a two-sided tape with a long title:
  all four tabs. The header is at most 150 points tall, the title is one line, the tab
  row doesn't wrap.
- With the scratch library: rename and delete a side from Side options; rename the
  side of a one-recording tape from Side options; type a
  description in Site Post, switch tab, switch back, and it's still there; change a
  level in Edit, switch tab, relaunch, and it was saved.

---

### Phase 4. Shelf list

**Goal.** The shelf as the mock's table, with status badges. The bottom panel goes.

**Mocks.** 01, without the hero.

**Needs.** Phase 3 (side management has moved).

**Files.**
- Add `RemanenceCore/Sources/RemanenceCore/ShelfStatus.swift`: one function from a
  `ShelfTape` (and whether it's recording) to a status: recording, failed, working
  (with job type), waiting, published, draft on site, on the site with no readable
  snapshot, approved, ready to review. Published comes from
  `SiteSnapshot.decode(...).published`, as `CatalogView.isPublished` does today. The
  no-snapshot case is its own value so Site Post can ask for a refresh (Phase 11), but
  its shelf badge reads "Draft on site", because the Catalog calls such a tape "Draft"
  today. No new status word.
- Add `RemanenceCore/Tests/RemanenceCoreTests/ShelfStatusTests.swift`.
- `Remanence/ShelfView.swift`: rewritten. Page header ("Library", "Shelf", count),
  "Import audio…" and "Record a tape"; tabs; the table. `TapeObject` stays in the file
  for the hero in Phase 5. `WrappingShelves` and `TapeColumn` are removed.
- `Remanence/AppModel.swift`: compute each tape's status once per shelf update, not per
  row per redraw (decoding the snapshot JSON in every row would be slow on scroll).
  `activityText` stays the source of the working wording.
- `Remanence/TapePanel.swift`: `TapePanel` removed; `TransportBar` stays (Read Along
  uses it). Rename the file if only the transport remains.
- `Remanence/LibraryView.swift`: no panel under the shelf or a collection.
- Footer note for the shelf, as 4.3's table says.

**Row behaviour.** One click selects (and loads the tape, as `select` does now, so Space
plays it). Double-click, Return, or a click on the title opens the workspace at Review.
The collection name opens the collection. See Q3.

**Must still work.**
- Right-click a tape: Collection submenu (toggle, New Collection…, Remove from
  Collection) and Move to Trash… with the same confirmation and refusals (being pushed,
  still recording).
- Drag a row onto a collection in the sidebar.
- A failed tape shows its reason (tooltip or second line) and Try Again.
- "Listening… 42%" progress while transcribing.
- The empty shelf screen with Import Backup…, and "Nothing here yet." for an empty tab.
- Tapes with no RA number show a dash, not "NEW" alone in a number column.

**Tests.** `ShelfStatusTests`: one per status, precedence (recording over working over
failed over site state), a pushed tape with no snapshot and one whose snapshot doesn't
decode (both the no-snapshot value, both labelled "Draft on site"), an approved unpushed
tape.

**Acceptance.**
- Build: 3.1 after `xcodegen`. Tests: 3.2.
- Layout at 900 by 692: all four tabs; a tab with no rows; 30 rows (scrolls, header
  stays); a 90-character title (truncates, columns hold); statuses of every kind. In the
  real library with the site pointed away, look only: Published and Draft on site badges
  match what the Catalog showed before.
- With the scratch library: drag a row to a collection; trash a tape; drop a file while
  on a filtered tab.

---

### Phase 5. Shelf memory and Resume

**Goal.** The hero above the list: the last tape worked on, and a Resume button that
reopens it at the same tab, side, playhead and zoom.

**Mocks.** 01 (hero).

**Needs.** Phase 4.

**Files.**
- Add `RemanenceCore/Sources/RemanenceCore/WorkPosition.swift`: a small `Codable`
  value (tape UUID, tab, source ID, playhead in master seconds, Review zoom start and
  span, Edit's selected track ID) and a function that checks it against the current
  shelf and clamps it.
- Add `RemanenceCore/Tests/RemanenceCoreTests/WorkPositionTests.swift`.
- `Remanence/AppModel.swift`: save the position to `UserDefaults` when leaving a tape,
  when switching tab, and at quit; load it at launch; `resume()` opens the workspace and
  applies it.
  - **Capture before the route changes.** `EditView.onDisappear` calls
    `EditModel.leave()`, which clears `expandedLaneID` and stops the player. A position
    read after that has no selected track and a stopped player. So the functions that
    change `route` (`switchTab`, back, sidebar selection, `resume`) read the position
    from the models first, then change the route. Nothing is captured from a view's
    `onDisappear`. At quit, capture in the app's terminate handler, before views go.
- `Remanence/ReviewModel.swift`: accept a zoom to restore. Today `observe(sourceID:)`
  sets zoom to 90 seconds centred on the playhead on the first update for a side
  (`isFirst`). Keep that for a newly opened side. For a restore, `AppModel` sets a
  pending zoom (source ID, start, span) before the screen appears. The first update
  for that source ID uses it in place of the 90-second default and clears it. Later
  updates from the same stream neither reset the zoom nor apply the value again. A
  pending zoom for a different source ID is dropped. This flag is on an app type, so no
  core test covers it; the acceptance steps below are its check.
- `Remanence/ShelfView.swift`: the hero, using `TapeObject` as the picture, with the
  "Last opened / RA-…" eyebrow, title, collection, medium, length, the Resume button and
  "at 0:42". The matching table row gets the picked background.

**Must still work.** Opening a tape from a row behaves as in Phase 4. With no saved
position, or a saved tape that's gone, there's no hero and nothing else moves.

**Tests.** `WorkPositionTests`: round trip; unknown tape gives nil; a removed side falls
back to the first side at 0; playhead past the end clamps; zoom wider than the side
clamps; a missing optional field decodes.

**Acceptance.**
- Build: 3.1 after `xcodegen`. Tests: 3.2.
- Layout at 900 by 692: hero with a reel, a cassette and a microcassette; a long title;
  at least six table rows still visible under the hero.
- With the scratch library: open a tape, go to side B, zoom in, move the playhead, go
  back to the shelf, quit, relaunch, Resume. Same side, playhead within 0.1 s, same
  zoom. Add a marker after resuming (a second update arrives): the zoom doesn't move.
  Open a different side: it gets the 90-second default. Leave from the Edit tab with a
  track selected, relaunch, Resume: Edit opens with that track selected. Delete that
  tape; the hero goes away.
- `library.sqlite`'s schema is unchanged (`sqlite3 … .schema` before and after).

---

### Phase 6. Review layout

**Goal.** Review as in mock 03.

**Mocks.** 03.

**Files.**
- `Remanence/ReviewView.swift`: 
  - Left: "Side A" with "Whole side 1:42", the overview strip and its ruler; "Close-up"
    with − and +, its ruler and the zoomed waveform; play and "0:42 / 1:42"; "Add marker
    M"; then the selected marker's row with its time in tenths, `0:34.0` (Hear the
    join, −0.1 s, +0.1 s, Delete); then "Trim side start I", "Trim side end O" and
    Undo. The I and O letters stay on the buttons, because the footer's hints don't
    list them.
  - Heights: the overview stays at about 58 points (58 today, 57 in the mock) and
    never grows or shrinks. The close-up takes the remaining height. It's 142 in the
    mock and has a minimum of 170 today; its minimum drops to 110 so the controls fit
    at 900 by 692.
  - Right: "Tracks on this side" as track rows, replacing the `.inspector`. In each
    row the small line is the side and the track's **start** ("Side A · 0:34") and the
    trailing number is its **duration** ("0:36").
  - "Side options ▾" moves from the header to the foot of this track column, under a
    rule, as the mock draws it. When the right column is hidden (Q5) the menu goes back
    to the header's subtitle line, so it's always reachable.
  - Marker flags show the track number; the time shows while one is dragged.
  - Key hints move to the footer note, still shortened by what fits. The mock's line is
    "Space Play / pause · J K L Shuttle · M Add marker".
- `Remanence/ReviewModel.swift`: nothing beyond Phase 5, except exposing the track under
  the playhead as "the selected track" (it's `TrackRow.isCurrent` today).

**Must still work.**
- Every key in `ReviewModel.handleKey`.
- Snap to quiet, and Option to place exactly. The checkbox isn't in the mock; keep it
  beside Add marker or in Side options (Q11).
- Trim Reset when a trim is set. Redo. "Keeping 1:20 of 1:42" when trimmed.
- Renaming a track in place. The mock shows names as plain text; make them editable on
  double-click, as Edit does, so M and Space aren't typed into a name.
- Clicking a track goes to its marker or start.
- Drag to scrub with sound, pinch to zoom, swipe to pan, drag a marker with snapping,
  the playhead staying in view while playing, Hear the Join.
- "Reading the waveform…" while peaks aren't ready.
- The line "Your master stays whole. Nothing is cut until you push to the site."

**Tests.** None new. `ReviewTests` and `TrackSpansTests` must pass unchanged.

**Acceptance.**
- Build: 3.1. Tests: 3.2.
- Layout at 900 by 692: no marker selected; marker selected; a trim set; 1 track and 14
  tracks (the list scrolls, the overview is still about 58 points, the close-up is at
  least 110); right column hidden, with Side options showing in the header. The marker
  row may wrap to two lines but nothing stacks letter by letter.
- With the scratch library, saying first that it plays sound: add, nudge, drag and
  delete markers by key and by pointer; undo and redo each; scrub; set and reset a trim.
  After a paused seek the clock and playhead both move.

---

### Phase 7. Edit layout

**Goal.** Edit as in mock 04: compact track rows, one close-up, one inspector.

**Mocks.** 04.

**Files.**
- `Remanence/EditView.swift`: restructured.
  - Left, top: "Tracks in site order" with the count, then one row per track: drag
    handle, site number, serif name, the side and the track's **duration** ("Side A /
    0:36" for "Muted ending"), and its waveform (30 points; 48 for the selected track,
    on the inset background). This is not the start time that Review's small line
    shows. Appended pieces stay indented under their track with "Then, as part of the
    same track".
  - Left, bottom, pinned: "<name> · close-up" with −, +, Whole track; ruler; the
    close-up with trim shading and handles; play and "Track 0:08 / Side 0:42"; "Split at
    playhead M".
  - Right: "Track 02 / Side A", name, Level, Speed, Direction, Trim start, Trim end
    (read-only, in hundredths: `0:00.48`), Track actions, the drag hint, and (from
    Phase 8) the return button.
  - Footer note: "Edits apply to playback and site copies · Master preserved". The
    sentence the screen has today, "Level, speed and direction are heard here and
    applied when you push. Your masters never change.", stays visible too, as the
    small line under the inspector's controls. On a locked tape it's replaced by the
    locked line, as now.
- `Remanence/EditModel.swift`: "selected track" is the existing `expandedLaneID`. Only
  these changes, and nothing else about selection, append or zoom:
  - When tracks first load and none is selected, select the playing track or the first.
  - Add `appendTargets(for:)` for the menu. It doesn't exist today; `append` does.
  - `toggleExpanded` is unchanged, so clicking the selected row again still collapses
    it. With nothing selected, the close-up and the inspector show one line, "Select a
    track".
  - No change to saving, playing, splitting, trimming or ordering.

**Must still work.** The mock omits these; all stay in the inspector or its menu.
- **Fit**, with "Measuring…", and the clipping warning under Level.
- Speed in 1% steps as well as ½×, 1×, 2×. The mock shows only a menu.
- Detach into Its Own Track for an appended piece.
- Reset Trim, and Reset Level, Speed and Direction.
- Join with Previous with its confirmation; append by dropping, with its confirmation
  and the same message; reorder by dropping between rows and by Move Up and Move Down.
- Rename by double-click, and `endTyping()` so keys reach Edit afterward.
- Scrubbing on a row's waveform and on trim handles, with sound; click to place the
  playhead; pinch, − and =, swipe; the playhead staying in view.
- Waveforms drawn at the track's level, reversed when reversed, red where clipping.
- A track with appended pieces playing through them; "3 pieces · 2:10".
- The locked state for a tape on the site: the line in red, every control disabled.
- Piece labels like "B1" (they're in the append and join messages).
- Renaming a side. Edit's side heading (`SideHeader`) goes, and it is today the only
  rename path for a tape with one recording. Before deleting it, confirm that Side
  options (Phase 3) renames the side of a one-recording tape. If it doesn't, stop and
  fix that first. See Q10.
- A visible line saying the masters never change (above).

**Tests.** None new. `ReviewTests`, `TrackSpansTests`, `PushTests` (appends, order,
trims) unchanged.

**Acceptance.**
- Build: 3.1. Tests: 3.2.
- Layout at 900 by 692: 1 track; 12 tracks across two sides (the list scrolls, the
  close-up stays put); a track with two appended pieces; a reversed track at ½×; the
  locked state; nothing selected; right column hidden. Level's slider, value and Fit
  sit on one line or wrap cleanly. Each row's number is its duration.
- With the scratch library, saying first that it plays sound: change level, speed and
  direction and hear each; split with M and with Option; join; trim both ends and reset;
  reorder by drag and by menu; append by drag and by menu; detach. Relaunch: all saved.
- The scratch masters' checksums are the same before and after (`shasum` over
  `masters/`).

---

### Phase 8. Review to Edit and back

**Goal.** "Edit selected track" opens Edit on that track at the same moment. "Return to
Side A" goes back to the side, same moment, same zoom.

**Mocks.** 03 (the button and its note), 04 (the return button).

**Needs.** Phases 5, 6 and 7. Phase 5 supplies the zoom-restore path the return uses.

**Files.**
- Add `RemanenceCore/Sources/RemanenceCore/TrackHandoff.swift`:
  - from a source ID and master time, the matching piece among `[PostTrack]` and the
    time clamped to what that piece plays. It walks each track's `pieces` (the head
    plus its `continuations`), not the top-level array, or audio appended to another
    track is never found;
  - from a piece and master time, the source and time for Review.
- Add `RemanenceCore/Tests/RemanenceCoreTests/TrackHandoffTests.swift`.
- `Remanence/AppModel.swift`:
  - `editSelectedTrack()` pauses the main player, leaves a pending target (source ID
    and master time) and switches to Edit.
  - `returnToSide()` **first** reads Edit's selected piece and playhead, **then**
    changes the route. The order matters: changing the route removes `EditView`, whose
    `onDisappear` calls `EditModel.leave()`, and that clears `expandedLaneID` and
    stops the player. After reading, it sets Review's pending zoom (Phase 5), switches
    to Review, chooses the side and seeks.
- `Remanence/EditModel.swift`: hold the pending target. `observe` keeps streaming for
  as long as the screen is up, so apply it exactly once: on the first update that has
  lanes, select the piece, load it, seek, bring the playhead into the close-up, then
  clear the target. Later updates must not re-apply it or move the selection. `leave()`
  also clears a target that was never applied. This is on an app type, so no core test
  covers it; the acceptance steps below are its check.
- `Remanence/ReviewView.swift`, `EditView.swift`: the two buttons and the note
  ("Open “Muted ending” at this position to adjust its trim, level or speed.").

**Must still work.** Both screens exactly as after Phases 6 and 7. Arriving never starts
playback. Nothing is written by a handoff.

**Tests.** `TrackHandoffTests`: a time inside the second of three tracks; exactly on a
marker; inside a trimmed-off part (goes to the nearest kept edge); before the side's
trim start and after its trim end; a track appended to another, built as a `PostTrack`
with `continuations` (found as its own piece, which a search of the top-level array
would miss); a reversed track; two sides (the right source); and the round trip back.

**Acceptance.**
- Build: 3.1 after `xcodegen`. Tests: 3.2 and 3.3.
- Layout at 900 by 692: the button and note under the track list; the return button at
  the foot of Edit's inspector; neither clipped.
- With the scratch library: in Review at 0:42 inside track 2 (which starts at 0:34),
  press the button. Edit shows track 2 selected with "Track 0:08 / Side 0:42". Move to
  0:12, return: Review is on the same side at 0:46 with the zoom it had. Repeat for a
  ½× track (the track clock reads heard time), for side B, and for a piece appended to
  another track. After arriving in Edit, rename a different track (a new update
  arrives): the selection and playhead don't jump back to the handoff target.

---

### Phase 9. Read Along tab

**Goal.** Read Along sits in the workspace like the other tabs, with the mock's
vocabulary.

**Mocks.** The Read Along dialog sketched in 03, 04 and 07. See Q2: this plan builds it
as a full tab, not a modal.

**Files.**
- `Remanence/ReadAlongView.swift`: transport and transcript in the main column in the
  new type; the right column holds About, Mentioned, "Tape notes" (the context field),
  the summary button, and "Compare transcripts…". Line editing is unchanged.

**Must still work.**
- **The approve toggle** that Phase 3 parked in this tab's body ("Looks Good /
  Approved", `setApproved(tape, !approved)`). It is the only control in the app that
  can clear approval; Site Post's button only sets it. Keep it, in the right column,
  until Phase 11 adds "Withdraw approval" to Site Post and removes it from here.
- Click a line to play from it; the pencil and right-click to edit; Save and Cancel;
  Return and Escape in the editor.
- Follow Along, and its pause when you scroll by hand.
- Mentioned names searching every tape.
- Notes saving on blur and on leaving.
- Write a Summary / Rewrite Summary and its disabled states.
- Try a Better Transcript, "Listening with the … model…", Compare Results and the
  comparison sheet. "Still listening" and "No words here".
- The transcript's line text uses `.fixedSize(horizontal: false, vertical: true)`
  today. That's safe only because it's inside a `ScrollView`; keep it there.

**Tests.** None new. `TranscriptTests` unchanged.

**Acceptance.**
- Build: 3.1. Tests: 3.2.
- Layout at 900 by 692: a long transcript; no transcript yet; no speech; a line being
  edited; right column hidden.
- With the scratch library: approve from Read Along, then take the approval back from
  Read Along. Both work.
- With the scratch library, saying first that it plays sound: open a search result and
  confirm it plays from the moment and the line is centred.

---

### Phase 10. Recording

**Goal.** The record screen as in mock 02, for every stage.

**Mocks.** 02. It shows recording and just-stopped. Setup, level check, the tape-end
question and Large Meter aren't drawn; they keep their content in the new layout (Q6).

**Files.**
- `Remanence/RecordView.swift` only. `RecordModel.swift` isn't edited.
  - Header: eyebrow "Capture / RA-019", title by stage ("Recording Side A", "Side A
    saved", and for setup a plain title such as "Record a tape"), subtitle with the
    name and collection.
  - Left: the dark meter panel in the meter tokens from 4.1 (panel `#292e29`, text
    `#f4efdc`). In it: the status badge, which reads "Recording" with the `#de886c` dot
    and then "Stopped" after Stop, as the mock's script does; "24-bit / 96 kHz" from
    the real format; the large clock in `timecode` form, `00:01:18`, always with hours
    (not `TimeLabel.clock`, which would read `1:18`); the VU face; "Input level"; the
    peak reading and the peak light.
  - Under the panel: "Input history · Last 12 seconds" (the existing strip is 120
    samples at 10 a second); Stop Side A and Add marker with the count; then the advice
    title and its sentence; then any warning lines.
  - Footer note: "RA-019 · Side A".
  - Right: "Tape label" with the number and "Write this number on the box." (before
    Record: "This tape will be RA-019. It's given when you press Record."); Capture
    settings; Machine note; Collection. Before Record these are the existing controls
    (machine, speed, name, collection with New Collection…, input, channels, note).
    While recording they're read-only rows.
  - After Stop: "Transcribing in the background." with Review Side A, Record Side B,
    Re-record Side A… and Shelf. **New Tape stays** (the mock omits it).

**Must still work.**
- Check Levels, its countdown, Cancel, its result, and the automatic channel switch.
- "Tape finished?" with Yes, Stop Recording and Keep Recording.
- All six level-advice states while recording, each with its title and its sentence
  from `RecordView.detail`, word for word: No signal, Too quiet, A little low, Levels
  look good, A little hot, Clipping. Clipping and Too quiet stay in the attention
  colour, and their sentence is on screen at the same time as the Stop button, without
  scrolling, because it tells you to stop.
- Dropout, stalled-input, disk-space and input-problem lines, in the attention colour.
  These are extra lines under the advice. They never take its place.
- Every control the unfinished Scarlett hardware pass in `native-app-plan.md` will
  need: input, channels, Check Levels, Large Meter, Record and Stop.
- The microphone permission screen.
- Large Meter, readable from across the room: the right column hides and the meter
  fills the window.
- Re-record's confirmation and its wording.
- Record disabled until the input is listening. Leaving refused while recording.
- Recording from an open collection preselects it.
- The number shown before Record is the one the tape gets.

**Tests.** None new. `RecordingTests` and `SidesTests` unchanged. Capture itself has no
automated test (it needs hardware), so this phase must not edit it.

**Acceptance.**
- Build: 3.1. Tests: 3.2.
- Layout at 900 by 692: setup; level check; recording; tape-end question; stopped;
  Large Meter; permission needed; clipping advice with two warning lines showing. The
  clock, Stop, the advice sentence and the tape label are all visible without scrolling
  in the recording state. The clock reads `00:00:00` form.
- Live check, only with the owner's go-ahead: run `scripts/dev/micuse.swift` first and
  stop if any app is using the input. Say that it records. With the scratch library,
  record 10 seconds, add two markers, stop, and check the saved file with `ffprobe`
  (rate and 24-bit), not the device's rate. Then Record Side B for 5 seconds, Re-record
  it, and Review. If Phase 2's navigation check is still open, do it during this
  recording. Remove the test tape. Quit normally.

---

### Phase 11. Site Post

**Goal.** Site Post as in mock 07: writing on the left, the site's state and one next
step on the right.

**Mocks.** 07.

**Files.**
- Add `RemanenceCore/Sources/RemanenceCore/SiteStage.swift`: one function from the
  facts the screen already has (on the site, snapshot read, published, approved, key
  saved, changes to send, blocked reason) to a stage: needs approval, needs key, ready
  to create draft, pushing, needs refresh, draft, draft with changes, published,
  published with changes. This is display logic only; it calls nothing.
- Add `RemanenceCore/Tests/RemanenceCoreTests/SiteStageTests.swift`.
- `Remanence/SitePostView.swift`: rearranged.
  - Left: "Site Post" with Save; Public title; Description; Estimated date and Medium;
    the finding line ("Joliet, Illinois · October 2023 (from collection)") with "Edit
    finding details…" opening the two existing fields; "Public tracks" with "Edit track
    order" (switches to the Edit tab).
  - Right: "Site status" with the stage's heading (Local only, Draft on site,
    Published), who can see it, the stage's main button, the smaller actions, the post
    photograph with "Manage photos…", and "Writing reference" with Claude's summary.
  - Footer note: "RA-019 · 3 tracks in site order".
- `Remanence/ReadAlongView.swift`: the approve toggle parked since Phase 3 is removed,
  as the last step of this phase, after "Withdraw approval" works here.
- `RemanenceCore/Tests/RemanenceCoreTests/PushTests.swift`: one added test (below). No
  existing test changes, and `Push.swift` isn't edited.

**Button mapping.** Same functions, new names.

| Mock | Calls |
|---|---|
| Approve for push | `model.setApproved(tape, true)` (was "Looks Good") |
| Withdraw approval (a small link under the approved state, only while the tape isn't on the site) | `model.setApproved(tape, false)`. Today only Read Along's toggle can do this. |
| Create unpublished draft | `push.start(tape)` (was "Push to Site"), "Try Again" after a failure |
| Publish reel / Unpublish reel | `push.setPublished`. Publish reel is the main button on a draft that matches the site. |
| Update on site | `push.update`, enabled only when there are changes. It's the main button only then (Q9); otherwise it's secondary text beside Refresh, as the mock draws it. |
| Refresh from site… | `push.refresh`, with the existing warning when changes are unsent |
| Remove from site… (in a "More" menu) | `push.deleteFromSite`, with the existing confirmation |

**Must still work.**
- Autosave after typing stops and on leaving. Save is an extra "save now".
- Only fields edited here are saved (the `saved…` copies), so a track renamed in Review
  isn't overwritten.
- Each track's name and description, and Claude's summary of a track with Use as a
  Starting Point and Copy. The mock's track rows are read-only; make each row open to
  show these (Q7).
- All photos: add, drop, caption, earlier, later, remove, and the `[photo 2]` hint.
  "Manage photos…" opens them; the column shows the first.
- "Claude suggests c. 1972. Use It" under the date.
- Fields disabled when the post needs a refresh or is syncing; the refresh explanation.
- "To send: …", "Matches the site.", and the notes for what can't be sent.
- Progress with Stop while pushing, and "Stopping keeps what's finished…".
- Every blocked reason (another push, recording, still processing, no medium, plan
  problem).
- The key field when no key is saved.
- **Conflict feedback:** when the site refuses a change because its copy is newer, the
  message (`syncFailure` or `failure`, as today) shows in the right column in the
  attention colour and stays until the next action.
- Approval can be set and taken back at the end of every phase, this one included.
- After a successful push, the tape's collection on the site is sent again
  (`joinCollectionOnSite`); untouched.

**Tests.** `SiteStageTests`: every stage; pushed with no snapshot is "needs refresh",
never "draft"; approved with no key; changes present on a draft and on a published
post; a blocked reason keeps the stage but disables its button; which button is the
main one on a draft with and without changes. One test added to `PushTests`: after a
first push, `FakeSite`'s entry has `published == false`. Nothing asserts that for
entries today (`CollectionsTests` does for collections). Existing tests in `PushTests`,
`SiteSyncTests` and `SitePostTests` are unchanged.

**Acceptance.**
- Build: 3.1 after `xcodegen`. Tests: 3.2.
- Layout at 900 by 692: not approved; approved with no key; ready; pushing; draft;
  draft with changes; published; needs refresh; a failure message of four lines; right
  column hidden. The stage's main button is always visible without scrolling.
  - The pushing layout is drawn from a sample progress value held in the view, for the
    screenshot only. `PushModel.progress` is `private(set)` and stays that way: no
    setter or debug hook is added to `PushModel`, because that would be a way to poke
    the push path. The sample value is deleted before the phase ends (check the diff).
- With the scratch library: type in every field, switch tabs and back; add, caption,
  reorder and remove photos; approve; withdraw approval; approve again. Then confirm
  Read Along no longer has the toggle.
- In the real library with the site pointed away, look only: a published post and a
  draft show the right stage. Click nothing in the right column.
- No button in this view calls `setPublished(true)` except Publish reel (read the diff).

---

### Phase 12. Collection

**Goal.** The collection page as in mock 05.

**Mocks.** 05.

**Needs.** Phase 4 (`ShelfStatus.swift`).

**Files.**
- `Remanence/CollectionView.swift`: rearranged.
  - Header: "Collection", the name, "where found · date"; buttons "Edit collection…"
    and "Manage site draft…".
  - Two columns: the write-up in the reading serif; "Box photographs" three across with
    italic captions and "Manage photos…".
  - "Reels in this collection" with "Add reels…", the note "Drag to set the
    collection’s reading order. Its public page lists published reels.", and the table:
    Order (handle and number), Number, Reel, Length, Site.
  - Footer note: "6 reels · 2 published reels · Collection draft on site", from the
    counts below.
  - "Edit collection…" opens a sheet with the existing name, where found, date acquired
    and write-up fields, and Delete Collection….
  - "Manage photos…" opens a sheet with the existing photo cards.
  - "Manage site draft…" opens a sheet with the existing site panel: status, Push to
    Site, Send Changes, Publish or Unpublish, progress, failure, notes, the count of
    reels not yet on the site, the page address, and Remove from Site….
- Add to `RemanenceCore/Sources/RemanenceCore/ShelfStatus.swift`: the footer's counts
  for a collection (reels, published reels, and the collection's own state).
- Extend `ShelfStatusTests.swift`.

**Must still work.**
- Typing saves after a pause, on closing the sheet, and before any push
  (`saveAndWait`). Typing is never saved to a different collection (`loadedID`).
- Drag reels to reorder; right-click to remove from the collection.
- Add photos by button and by drop; captions; earlier, later, remove.
- Both delete paths and their wording: here only, or here and from the site.
- Send Changes enabled only when something differs. `collectionFailure` shows in the
  site sheet and stays visible. A first "changed on the site" conflict won't appear
  there, because `CollectionSync` re-sends past it (section 1). That's today's
  behaviour; don't add a message for it.
- An empty collection's help text.
- The write-up is long text: it must sit inside the page's `ScrollView`.

**Tests.** Footer counts: none published; some published; a collection not on the site,
a draft, and a published one. `CollectionsTests` and the collection pushes in
`PushTests` unchanged.

**Acceptance.**
- Build: 3.1. Tests: 3.2.
- Layout at 900 by 692: no write-up and no photos; a six-paragraph write-up; 1, 3 and 9
  photos; 0, 1 and 12 reels; each sheet. The two columns stack below a set width
  instead of squeezing.
- With the scratch library: edit every field, close the sheet, relaunch; reorder reels;
  add reels; add and remove photos.
- The site sheet with the site pointed away: Push to Site isn't clicked. Its disabled
  and enabled states are checked by reading, and its behaviour by the existing tests.

---

### Phase 13. Catalog

**Goal.** The Catalog as in mock 06, with its staging rules moved somewhere testable.

**Mocks.** 06.

**Files.**
- Add `RemanenceCore/Sources/RemanenceCore/CatalogStaging.swift`: the staging that
  lives in `CatalogView`'s `@State` today (`staged`, `order`), as a plain value.
  **Copied exactly** from the view's `move`, `stage`, `commitTyping`, `changes` and
  `reset`:
  - `move`: dragging deals the same set of numbers out in the new order, so the reels
    between where one was and where it went each shift by one. Dragging is the only
    thing that changes more than one reel.
  - `commitTyping`: typing stages **that one reel** and re-sorts the list. It never
    touches another reel, even when the typed number belongs to one. A taken number is
    staged as typed; Apply then fails in `Library.checkRenumbering` with
    `CatalogError.taken` or `.duplicate`, and that text shows in the pending column.
    Typing is not a swap.
  - Blank input puts the reel's original number back, which undoes its staged change.
    It does not clear a number.
  - Text that isn't a catalog number changes nothing and reports "“…” isn’t a catalog
    number. They look like RA-012."
  - `stage`: a number set back to its original is no longer a change.
  - `changes` gives the list of `Renumbering`; `reset` clears everything and follows
    the shelf.

  **Added** (new, small, and not in the view today):
  - The pending pairs for the right column, and a heading. The heading is display
    only. It reads "Swap two numbers" in exactly the case the mock draws: two staged
    reels, each given the other's current number. Anything else reads "Renumber 1 reel"
    or "Renumber 3 reels".
  - A tape deleted while staged is dropped from `order` and `staged`. Today the view
    resets only when nothing is staged, so a deleted tape's ID stays in `order`, and a
    later drag would deal a number to a tape that no longer exists. The new function
    takes the current shelf and removes IDs that aren't in it. Other staged changes
    are kept.
- Add `RemanenceCore/Tests/RemanenceCoreTests/CatalogStagingTests.swift`.
- `Remanence/CatalogView.swift`: 
  - Header: "Catalog", with the subtitle "RA numbers match the labels on the boxes."
  - Left: "By RA number" with the count; table of Move, Current, Reel, Proposed;
    changed rows highlighted; the drag-or-type note; the "No number" section. The Reel
    cell keeps the collection name as a small second line under the title. Today it's
    a 190-point column of its own; the mock has no room for that column, and the name
    is how a box is recognised (Q13).
  - Right: "Pending changes": the heading, each reel with "RA-031 → RA-037" and its
    site state, the explanation, "Apply 2 changes…" and Revert. Failure text shows
    here.
  - The explanation depends on what's staged. For a swap it's the mock's sentence:
    "Apply both changes together. Old site addresses redirect to the new numbers.
    Update the labels on both boxes afterward." For anything else it's "Relabel the
    boxes to match.", the line today's confirmation ends with.
  - Footer note: "2 proposed changes · Awaiting confirmation".
- `Remanence/AppModel.swift`: hold the staging value in memory so it survives going to
  another screen and back (Q13). It is never written to `UserDefaults` or the database,
  and is gone at Apply, Revert or quit.

**Must still work.**
- The confirmation before applying, with its message: how many are on the site, how
  many are public and keep their old address, and "Relabel the boxes to match."
- Apply goes through `PushModel.renumber`: the site first, checked against its clock,
  then here. Refused while anything else is being sent.
- After Apply: "Renumbered 2 reels. Relabel their boxes."
- With nothing staged, the list follows the shelf.
- Whether each reel is on the site and public (today's last column). The mock drops the
  column; show it in the pending list for changed reels at least.
- Each reel's collection name (above).
- A taken or duplicated number is refused at Apply with the library's own message, and
  nothing is renumbered.

**Tests.** `CatalogStagingTests`, each with its expected result:
- Drag one reel down three places: four changes, the same set of numbers.
- Type a free number: one change.
- Type a number another reel holds: one change, for the typed reel only. The other
  reel is not staged and keeps its number.
- Type nonsense: no change, and the "isn't a catalog number" message.
- Type blank on a reel with a staged change: its original number is back and it's no
  longer a change. Blank on an unstaged reel: nothing happens.
- Type a reel's original number: its change is gone.
- Revert: nothing staged, order follows the shelf.
- An unnumbered tape given a number: one change, and it joins the ordered list.
- A tape deleted while staged: gone from `order` and `staged`; other staged changes
  are intact; a drag afterward deals numbers only to tapes that exist.
- The heading for 1 change, 2 that trade numbers ("Swap two numbers"), 2 that don't
  trade, and 5.

`CatalogTests` and the renumber cases in `PushTests` unchanged.

**Acceptance.**
- Build: 3.1 after `xcodegen`. Tests: 3.2.
- Layout at 900 by 692: nothing staged; a swap; eight changes (the pending list
  scrolls, Apply stays visible); a failure message; unnumbered tapes present.
- With the scratch library, and `-siteURL` pointed away as on every launch. No scratch
  reel is on the site, so Apply sends no renumber. It still calls
  `refreshSiteNumbers()` afterward, which lists the site whenever a key is in the
  Keychain. `-siteURL` is the only thing keeping that read off the live site, so check
  the launch command before clicking Apply.
  - Stage a swap by dragging one reel past its neighbour. Leave, come back (still
    staged), apply, and confirm both numbers changed.
  - Stage a swap by typing each reel's new number (two entries; typing one doesn't
    move the other). The heading reads "Swap two numbers". Apply.
  - Type a taken number into one reel only and apply: it's refused with the library's
    message and nothing changes.
  - Revert a staged change. Stage a change, trash that tape, and drag another reel:
    nothing odd is staged.
- Never apply in the real library during this work.

---

### Phase 14. Site Posts, search, setup, and the final pass

**Goal.** The remaining screens in the new language, then a check of the whole flow.

**Mocks.** The Site Posts table sketched in the unused dialog of each mock (Number,
Title, Status, Open or Bring in, Reload). Search results, Setup and empty states have
no mock; they take the shared parts from Phase 1.

**Files.**
- `Remanence/SitePostsView.swift`: page header, Reload, the table with status badges,
  Open (to the tape's Site Post tab), Bring In with its progress. The Status column
  describes the site's entry, not a library tape, so it does not go through
  `ShelfStatus`. A row with no local tape reads "Site only", as the mock's dialog has
  it, with Bring in. A row that has a local tape shows the entry's Published or Draft
  state, as the view works it out today.
- `Remanence/SearchResultsView.swift`, `Remanence/SetupView.swift`, the empty shelf and
  the drop overlay in `LibraryView.swift`: type and colour only.
- Docs, when the owner asks for them: the status section of `docs/native-app-plan.md`,
  and `CLAUDE.md` if the layout table or traps changed.
- Deletions, by name. Delete only these, and only after a search shows no caller:
  - any private back-button, title or cross-link helper left in `ReviewView.swift`,
    `EditView.swift`, `ReadAlongView.swift` or `SitePostView.swift` from Phase 3;
  - leftover sheet-only code in `CatalogView.swift` and `SitePostsView.swift` (the
    fixed frame and Done button, if anything of them remains from Phase 2);
  - a `Theme` alias from Phase 1 (`card`, `board`, `inkMuted`) once nothing calls it.

  Already gone by now, so just confirm: `WrappingShelves`, `TapeColumn` and `TapePanel`
  (Phase 4), `SideHeader` (Phase 7).

  **Keep:** `TapeObject` (the shelf hero uses it), `TransportBar` (Read Along uses
  it), `TimeLabel` and `ReviewTime` (forwarders with callers). Nothing else is deleted
  in this phase without asking.

**Must still work.** Bring In's refusals (a push running, recording, a post with no
audio) and its "Track 2 of 5"; the listing's failure text; "Check Again" and model
downloads in Setup; search summary and "Nothing matches".

**Tests.** None new.

**Acceptance.**
- Build: 3.1 after `xcodegen`, no warnings. Tests: 3.2 and 3.3; the count is the
  baseline plus every test added in phases 1, 2, 3, 4, 5, 8, 11, 12 and 13.
- Layout: every screen at 900 by 692, at 860 by 640, and at 1440 by 900 beside its
  mock.
- One walk through the flow in the scratch library: import, open, mark tracks, Edit
  selected track, return, Read Along, Site Post up to Approve, collection, Catalog swap,
  back to the shelf, Resume.
- Hard-rule check: `git diff` against the start shows no change in the files named in
  section 1's first three rows and no new migration; scratch masters' checksums match;
  the real library's `library.sqlite` schema is unchanged.

---

## 8. Open UI questions

Each has the default this plan uses, so work isn't blocked. The owner's answer may
change the phase named.

| # | Question | Default in this plan | Phase |
|---|---|---|---|
| Q1 | Is Site Posts a full page or a sheet? The sidebar links to it, but the only drawing is an unopened dialog. | Full page | 2, 14 |
| Q2 | Is Read Along a tab or a modal? It's drawn as a small dialog but listed as one of four tabs. | Tab. The transcript needs the room, and search opens it. | 9 |
| Q3 | What does a shelf row do, and where does quick play go? The bottom panel with play and scrub isn't in the mock. | Click selects, Space plays, double-click opens Review. No visible transport on the shelf. | 4 |
| Q4 | What does Resume remember, and for which tapes? | One position, for the last tape only. Rows open at Review as today. The button reads "Resume Side A", or "Resume" for a tape with one unnamed recording, and reopens the tab you left. | 5 |
| Q5 | At 900 by 692 the right column leaves about 390 points for waveforms. May it be hidden? | Yes: narrower in compact, with a toolbar toggle, as Review's inspector has today. | 3, 6, 7, 11 |
| Q6 | Recording before Record isn't drawn. Where do Name, Check Levels, Large Meter and New Tape go? | Setup controls fill the right column; Check Levels sits beside Record; Large Meter is a toolbar button; New Tape joins the after-Stop row. | 10 |
| Q7 | Site Post's track rows are read-only in the mock. Where are track names and descriptions written? | Each row opens to show them. | 11 |
| Q8 | Can approval be taken back? Read Along's button toggles it today; the mock has no such control. | A small "Withdraw approval" link under the approved state, calling `setApproved(tape, false)`, offered while the tape isn't on the site (today's rule). Read Along keeps its toggle until this exists. | 9, 11 |
| Q9 | On a draft with unsent changes, which is the main button: Update on site or Publish reel? | With unsent changes: Update on site, with Publish beside it. With none, as the mock draws: Publish reel is the main button, and Update and Refresh are secondary text. | 11 |
| Q10 | Edit: the mock omits Fit, 1% speed steps, Detach, the resets, side headings, and how appended pieces look. May trims be typed? | All kept in the inspector or its menu. Side headings go; rows carry the side. Trims are read-only numbers. | 7 |
| Q11 | What's in "Side options", and where is Snap to quiet? | Rename Side… (also for a one-recording tape), Delete Side… (two or more recordings). It sits at the foot of Review's track column, as drawn, and in the header when that column is hidden. Snap to quiet stays as a checkbox by Add marker. | 3, 6 |
| Q12 | Collection: is editing in a sheet? Where are Delete Collection and Remove from Site? Can Add reels take a reel from another collection? | Sheets for editing, photos and the site draft. Delete in the edit sheet, Remove in the site sheet. Add reels lists every other tape and shows its current collection. | 12 |
| Q13 | Catalog: what happens to staged changes when you go elsewhere? Are the collection and site columns gone for good? | Staged changes are kept in memory until Apply, Revert or quit, and the footer shows the count. The collection name stays, as a small line under each reel's title. Site state leaves the table and shows in the pending list for changed reels. | 13 |
| Q14 | Words: "reels" everywhere, when the library also has cassettes and microcassettes? "Transcribing" or today's "Listening…"? What's an approved, unpushed tape called? What's a pushed tape called when its site snapshot can't be read? | "Reels" in headings as the mocks have it, "tape" for a cassette's own row and messages. Keep "Listening… 42%", in the shelf footer too. "Approved for push". "Draft on site", matching the Catalog's "Draft" today. | 4, 14 |
| Q15 | What does Setup show once everything is installed? Does the site key move there from Site Post? | The existing checklist only. The key stays where it is. | 2, 14 |
| Q16 | Does "Local library" in the footer mean anything, such as a connection state? | A fixed label ("Scratch library" in test launches). | 2 |
| Q17 | The mock's sidebar has no counts. Keep the count beside each collection? | Keep it. It's small and already there. | 2 |
| Q18 | The drawn shelf of tape boxes goes away. Keep it as a second view? | No. The drawing survives in the hero. | 4 |
| Q19 | Iowan Old Style or the system serif (New York) the app uses now? | Iowan Old Style, with the mocks' and proposal's fallbacks in order: Palatino Linotype, Palatino, Georgia, then the generic serif. | 1 |
| Q20 | When a tape is opened from a collection, is the first crumb "Shelf" (as drawn) or the collection? | Where you came from: the collection's name, or "Results" from search. | 3 |
| Q21 | Should the breadcrumb sit in the native toolbar, or in a drawn bar as in the mocks? | Native toolbar. | 2 |
| Q22 | Is the `-libraryPath` test launch argument acceptable? | Yes, read from the launch arguments only. | 0 |
| Q23 | Which branch do commits go on? `CLAUDE.md` says `native-app`; the work is on `redesign`. | Ask before the first commit. | all |

---

## 9. Risks

| Risk | Why it matters | What limits it |
|---|---|---|
| Reaching the live site during a check | A key is in the Keychain. Opening Recording, Catalog or Site Posts reads the site, and Publish, Update, Apply and Delete write to it. | `-siteURL` on every launch (3.4); the footer could show when it's set; no write-type click outside the scratch library. |
| Touching the real library | The app has no other library until Phase 0. | Phase 0 first. Checksums over scratch masters in phases 7 and 14. |
| Width at 900 by 692 | Sidebar 220 plus a right column leaves under 400 points. Rows of buttons can stack letter by letter (a trap already hit). | Size classes (4.2), a hideable right column (Q5), `.fixedSize()` on every label and button in such rows, `ViewThatFits` for button rows, and a check at 860 by 640. |
| The window growing off-screen | Long serif text (write-up, description, transcript lines) with a vertical `fixedSize` outside a `ScrollView`. | Keep all reading text inside the page's `ScrollView`. Phases 9, 11 and 12 call it out. |
| Edit is rebuilt | `EditView` is 941 lines of gestures, focus handling and drag targets. A regression could mis-set a trim or split. | Phase 7 changes layout only; `EditModel`'s saving is untouched, and its selection, append and zoom change only as Phase 7 lists; a full manual pass; checksums prove masters are unchanged. Nothing is cut until push anyway. |
| Two players in the handoff | Review uses `AudioPlayer` on the master; Edit uses `TrackPlayer` with level, speed and direction. Positions must agree, and both must not play at once. | Positions are master seconds on both sides; the mapping is tested in the core; arriving always pauses. |
| Edit's tracks load late | `EditModel.observe` fills tracks asynchronously, so a target applied too early is lost. | A pending target applied once, on the first update with lanes, then cleared (Phase 8). |
| `EditModel.leave()` runs when Edit disappears | It clears the selected track and stops the player. A work position or a return handoff read after it sees nothing. | Phases 5 and 8 read from the models before changing `route`, never from `onDisappear`. |
| A later `observe` update undoes a restore | Review's and Edit's streams keep sending updates. A restore flag that's re-applied, or a default that's re-run, would move the zoom or selection under the user. No core test can see this. | Each flag is consumed on the first matching update (Phases 5 and 8), and each phase's manual check makes a second update arrive. |
| Review resets its zoom | `ReviewModel.observe` re-centres at 90 seconds each time it appears, which would defeat Resume and Return. | Phase 5 adds a restore path and leaves the default for newly opened sides. |
| Saves on leaving | Site Post, Edit, the collection and Read Along save in `onDisappear`. A tab kept alive but hidden wouldn't save; a sheet changes when "leaving" happens. | Tabs are removed from the tree (4.3). Sheets save on dismiss. Each phase tests type, switch, relaunch. |
| Keys and swipes are routed by `route` | `AppDelegate` checks `route == .review` and `.edit`. Changing the cases would silently break M, Space, J K L and ⌘Z. | Keep the four cases (4.3). Phase 3 checks every key. |
| Recording survives navigation | With a permanent sidebar it's easier to wander off mid-recording. `close()` runs in `onDisappear`. | `close()` already refuses while recording. A recording dot in the sidebar. Phase 2 checks it with a real recording, after `micuse.swift` and a go-ahead, or hands the check to Phase 10. A level check proves nothing here. |
| Catalog reorder | Today's drag uses `List.onMove`. A custom table loses it. | Keep a `List` styled as the table, or reuse the collection's drop-gap rows. Staging is tested in the core either way. |
| Status per row | Decoding each tape's site snapshot JSON in every row would slow scrolling. | Computed once per shelf update (Phase 4). |
| Losing a feature the mocks don't draw | Level check, tape-end question, Large Meter, New Tape, Fit, fine speed, Detach, track descriptions, snap to quiet, redo, un-approve, side rename and delete. | Each phase's "Must still work" list is its checklist. Section 8 names the ones needing a home. |
| Wording changes hide meaning | "Create unpublished draft" must not read as, or become, publishing. | The mapping table in Phase 11, and its diff check that only Publish reel calls `setPublished(true)`. `Push.swift` isn't edited. `SiteEntry`, the create body, has no `published` field, so a first push can't publish. `publishingIsSentOnlyWhenAsked` checks that an update leaves `published` out unless asked. No test asserts a new entry is unpublished today (`CollectionsTests` asserts `state.published == false` for collections), so Phase 11 adds that one assertion to `PushTests`. |
| Apply in the scratch library still reads the site | `PushModel.renumber` always ends with `refreshSiteNumbers()`, which lists entries when a key is stored, even when no reel was on the site. | `-siteURL` on the launch (3.4); Phase 13 says to check it before Apply. |
| A debug hook into pushing | Faking push progress through `PushModel` would add a setter to the push path. | `progress` stays `private(set)`. Phase 11 draws the pushing layout from a sample value inside the view and deletes it. |
| "Before" pictures miss states | A scratch library of three tones has nothing pushed, published or transcribed by a real voice. | Phase 0 lists what it can show and takes the rest from the real library, looking only. |
| Seeding steals focus | A real drag onto the Dock icon brings the app forward and may land in whatever the owner is doing. | Phase 0 sends files through the open-file path in the background, or drops on the scratch window with `scripts/dev/app.swift`. |
| The final pass deletes something in use | "Unused" is easy to get wrong: `TapeObject` feeds the hero and `TransportBar` feeds Read Along. | Phase 14 names what may go and what stays. |
| The hardware pass is still owed | `native-app-plan.md` has the Scarlett pass unfinished, and Phase 10 rewrites the screen it uses. | Phase 10's must-still-work list names the controls that pass needs. |
| Inspector and toolbar | Review and Read Along use `.inspector` with a toolbar toggle. A fixed column inside a tab container may fight the split view's toolbar. | Phase 3 keeps the inspectors; phases 6, 7 and 11 replace them one at a time, each checked at 900 by 692. |
| Font availability | Iowan Old Style ships with macOS, but a custom font name that doesn't resolve falls back silently to sans. | One helper that tries each name in the stack (Iowan Old Style, Palatino Linotype, Palatino, Georgia) and ends at the generic serif, never sans; Phase 1 compares against the mock. |
| Baseline unverified | The 329 figure wasn't re-run while planning. | Phase 0 runs it before any change. |
| Hardware-only paths | Capture has no automated tests. | Phase 10 edits `RecordView.swift` only, and its live check needs the owner's go-ahead. |

---

## 10. Review response

`docs/redesign/plan-review.md` was checked against the code and the mocks before any
of it was used. The phase structure is unchanged: the same 15 phases in the same order.
Section 6 now says they're built one at a time, with the real dependencies.

**Required changes: all 14 made.**

| # | Change | Where |
|---|---|---|
| 1 | Font stack with Palatino Linotype and Georgia | 4.1, Q19, risks |
| 2 | Old `Theme` names kept as aliases; `TimeLabel` and `ReviewTime` kept as forwarders | 4.1, Phase 1 |
| 3 | Catalog typing stages one reel and is never a swap; blank restores; deleted tape dropped; "copied exactly" narrowed | Phase 13 |
| 4 | Collection name stays in the Catalog | Phase 13, Q13 |
| 5 | Staged catalog changes in memory only | Section 1, Phase 13 |
| 6 | Real dependencies and shared files | Section 6 |
| 7 | Read Along keeps the approve toggle; "Withdraw approval" added | Phases 9 and 11, Q8 |
| 8 | Read positions before `EditModel.leave()`; pending target applied once; walk `pieces` | Phases 5 and 8 |
| 9 | Navigation check uses a real recording, after `micuse.swift` and a go-ahead | Phase 2 |
| 10 | Overview about 58, close-up minimum 110; I and O on the trim buttons; Side options at the foot of the track column; start versus duration | Phase 6 |
| 11 | Edit rows show duration; masters line kept; single-side rename in Side options | Phases 3 and 7 |
| 12 | `timecode` clock, badge wording, six advice states, meter colours | Phase 10, 4.1 |
| 13 | Collection conflict is absorbed on purpose; scratch Apply still reads the site | Section 1, Phases 12 and 13 |
| 14 | Deletions named; "Site only" kept out of `ShelfStatus` | Phase 14 |

**Suggestions: all adopted but one, which is adopted in part.**

- Adopted: the mock's footer sentences (4.3); Catalog subtitle and a swap-only
  explanation; the collection drag note quoted; badge text in ink; separate eyebrow and
  cap styles; hero title, track name and padding sizes (4.2); Q9's other case; "Draft
  on site" for a pushed tape with no snapshot, in place of a new status word; a
  view-local sample for the pushing layout; what Phase 0's pictures can show, and
  seeding without the Dock; the corrected risk row plus one added `PushTests`
  assertion; a small core type for where Back goes (`TapeOrigin`, Phase 3); the note
  that 3.3 adds no coverage over 3.2.
- Adopted in part: keeping `toggleExpanded`'s collapse on a second click. It's kept,
  and the Escape shortcut is dropped. One addition the suggestion didn't cover: with a
  single pinned close-up, a collapsed selection needs something to show, so the
  close-up and inspector read "Select a track". Rejecting the collapse would have been
  simpler, but it would change `EditModel`'s selection in the riskiest phase.

**Where the review was not quite right.** Neither changes a required fix.

- Item 3 lists "a tape deleted while staged is removed from `order` and `staged`"
  alongside the behaviour to copy. The view doesn't do that today: it resets only when
  nothing is staged, so a deleted tape's ID stays. The plan adds the removal as new
  behaviour and labels it so.
- Item 11 says `SideHeader` is the rename path for a tape with one recording. It is,
  but only when that recording has a side name (`lane.side != nil`) and the tape isn't
  on the site. A recording with no side shows "Recording" and can't be renamed there.
  Side options copies that rule and doesn't widen it.

**Not re-verified.** The review's read-only confirmations of things the plan already
said (filter rules, key routing, Bring In's refusals, menu commands) were spot-checked,
not all re-read. The test suite still hasn't been run; Phase 0 does that.
