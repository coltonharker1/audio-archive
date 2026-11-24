# Review of `docs/redesign/plan.md`

The plan matches the app and the mocks well enough to build from. The hard rules point at the right files, the 329 `@Test` count in `RemanenceCore/Tests` matches `docs/recent-work.md`, and the screen map in section 2 is accurate. Several phase instructions contradict the code or the mocks, and section 6 overstates how independently phases 4–13 can be built. Those should be corrected before implementation starts.

I did not run the test suite or modify anything. The 329 figure is a count of `@Test` functions in the tree, not a fresh `swift test` run. Some of those tests are skipped unless `ffmpeg` is on the machine (`hasTools` / `hasFFmpeg`), `REMANENCE_NETWORK_TESTS=1`, or `REMANENCE_LIBRARY` is set.

## Fidelity to the mocks

What the plan reads correctly:

- Shared chrome: 220-point rail, wordmark, Recording, Library (Shelf, Catalog, Site Posts), Collections, New collection, Setup in the rail foot, breadcrumb, search, one-line footer. Tokens in section 4.1 match the shared CSS (`#faf5ee`, `#211d19`, `#696156`, `#dcd4c8`, `#ede7dd` / `#dbd3c6`, `#f4eee5` / `#f2ece2`, `#eae2d4`, `#eee7dc`, `#efe7da`, `#914d37`, `#9d4e35`, `#81533d`, status dots `#61775d` `#9e8054` `#a36245` `#88877a`, waveform stroke `#716e5d`).
- Shelf (`01-shelf.html`): hero, Resume, four tabs with counts, columns Number / Reel / Collection / Length / Status.
- Recording (`02-recording.html` and its script): the stop handler sets the title to "Side A saved", the badge to "Stopped", and the next step to "Transcribing in the background." plus Review Side A, Record Side B, Re-record Side A…, and Shelf. Keeping New Tape is the right preservation call. The history strip in `RecordView` is 120 samples at 10 Hz, which is 12 seconds. `CaptureFile` always writes 24-bit, and the rate comes from the device.
- Review and Edit headers, tabs, "Edit selected track", the note about "Muted ending", and "← Return to Side A".
- Edit row waveforms are 30px and 48px for the selected row, as Phase 7 says.
- Collection (`05-collection.html`): read-only page, italic captions, three-across photos, reel table, footer counts.
- Catalog (`06-catalog.html`): Current / Proposed, pending column, "Swap two numbers", "Apply 2 changes…", footer "2 proposed changes · Awaiting confirmation".
- Site Post (`07-push-publish.html`): the script really does run Local only (already approved) → Create unpublished draft → Draft on site with Publish reel as the main button → Published with Unpublish reel. Update and Refresh appear as secondary text on the draft step.
- Q1 and Q2 are fair. Site Posts is an unopened `<dialog id="posts">` copied into every mock, and nothing opens it. The sidebar link points at `07-push-publish.html`, which is one tape's Site Post, with Shelf selected. Read Along is a tab that calls `reader.showModal()`.

Misses and misreads:

- The font stack in every mock, and in `proposal.md`, is Iowan Old Style, Palatino Linotype, Palatino, Georgia, then generic serif. Section 4.1 and Q19 drop Georgia and fall back to "the system serif". On macOS that is not Georgia.
- `Theme` today is `paper`, `card`, `board`, `ink`, `inkMuted`, `accent`, `good`, `attention`, plus `display()`. Section 4.1 never says what replaces `card` and `board`. Those two are used all over `Remanence/`.
- The recording clock in the mock is `00:01:18` (always hours). `TimeLabel.clock` in `RemanenceApp.swift` renders that moment as `1:18`. Phase 10 says "the large clock" and never points it at the new `timecode` helper.
- Review marker time in the mock is tenths (`0:34.0`), which is `ReviewTime.precise`. Edit trims are hundredths (`0:00.48`, `0:36.00`). The plan adds both formatters and does not say which screen uses which.
- Review track rows and Edit rows use the same digits for different fields. In `03-tape-review.html`, "Side A · 0:00" is the start and "0:34" is the duration. In `04-edit.html`, "Side A / 0:34" is the duration. Phase 7's example "Side A / 0:34" is track 1, where those two numbers happen to match the next track's start.
- "Side options ▾" sits at the foot of the track column in `03-tape-review.html`. Phase 3 puts it in the header.
- The mock's trim buttons are "Trim side start I" and "Trim side end O". The footer hint line is only "Space Play / pause J K L Shuttle M Add marker". I and O are not in that footer. Phase 6 drops the letters.
- Phase 6's "waveforms don't shrink below 110 points" matches neither the mock (overview 57px, close-up 142px) nor `ReviewView` today (overview 58, close-up minimum 170). Applied to both strips, it makes the overview almost twice the mock.
- The recording badge dot is `#de886c` on a panel of `#292e29` / `#f4efdc`. Section 4.1 has neither.
- Footers the phases never assign: shelf "Background activity · Transcribing RA-028" (Phase 2 defaults the footer to `pipelineSummary`, which reads "1 tape in progress"), recording "RA-019 · Side A", Site Post "RA-019 · 3 tracks in site order". Phase 7 never mentions the edit footer "Edits apply to playback and site copies · Master preserved", and the must-still-work list drops the sentence now in `EditView`: "Your masters never change."
- Catalog page subtitle "RA numbers match the labels on the boxes." is not in Phase 13. The pending-column sentence ("Apply both changes together. Old site addresses redirect…") is swap-specific. The plan says "the explanation" without saying it changes when the change is not a swap.
- Collection drag note: "Drag to set the collection’s reading order. Its public page lists published reels." Phase 12 says "the drag note" and does not quote the public-page half.
- Site Posts rows that are not in the library say "Site only". That is not a `ShelfTape` status. Phase 14's table will get this wrong if it reuses `ShelfStatus`.

Deliberate deviations that should stay, because the plan already names them: native toolbar instead of the drawn lights-in-the-rail (`§4.3`, Q21), Read Along as a tab (Q2), Site Posts as a page (Q1), "Listening… 42%" rather than the mock's "Transcribing" (Q14), read-only trims (N11), a hideable right column (Q5), and `-libraryPath` (Q22). The proposal asks for native window chrome, so refusing a fake title bar is right.

## Phase order and independence

Numeric order 0 through 14 can leave a working app, with two holes. The overview in section 6 cannot. It says that after Phase 3, phases 4–13 depend only on "5 needs 4; 8 needs 6 and 7". These also share files or behaviour:

| Phase | Also depends on | Why |
|---|---|---|
| 8 | 5 | `returnToSide()` "asks Review to keep its zoom". That path is added in Phase 5 because `ReviewModel.observe` resets `zoomSpan` to 90 on every fresh observe. |
| 12 | 4 | It extends `ShelfStatus.swift`, which Phase 4 creates. |
| 9 then 11 | each other, in that order | Both edit `ReadAlongView.swift`. |
| 5 and 6 | not parallel | Both edit `ReviewModel.swift`. |
| 4, 5, 8, 13 | not parallel | All edit `AppModel.swift`. 4 and 5 also edit `ShelfView.swift`. |

Phase 9 is not safe on its own. Phase 3 parks the approve toggle in the Read Along body until Phase 11. Phase 9 rewrites `ReadAlongView.swift` and its must-still-work list does not mention that toggle. `SitePostView`'s "Looks Good" only calls `setApproved(tape, true)`. The toggle that can clear approval is in `ReadAlongView` (`setApproved(tape, !approved)`). Drop it in Phase 9 and approval cannot be set or withdrawn until Phase 11.

Phase 10 only touches `RecordView.swift` and can sit anywhere after Phase 2. Phase 13 only needs the Catalog route from Phase 2.

## Existing behaviour

The must-still-work lists are mostly real. Checked against the code:

- `ShelfFilter.includes`: approved and unpushed is in All only. In Progress is `failed` plus `TapeStatus.isActive` (waiting and working). On the Site is `pushedAt != nil`.
- `openRecording()` refuses while `pushModel.isPushing`. `RecordModel.close()` returns immediately only while `isRecording`. `RecordView.onDisappear` always calls `close()`.
- `AppDelegate` routes ⌘Z to Review only, and horizontal scroll to Review and Edit. Space and arrows work whenever `player.currentURL != nil` and the first responder is not a text field. `select` loads the master, so Space on the shelf works after the panel is gone.
- `openReview`, `openEdit`, and `openPost` each overwrite `routeBeforeReadAlong`. From Read Along, `route` is `.readAlong`, so a later tab switch through those functions loses "Results". `switchTab` is the right fix. Search really does open Read Along, seek, and play (`AppModel.openResult`).
- Side rename and delete in `TapePanel` exist only when `items.count > 1` and `pushedAt == nil`. A one-recording tape is renamed by double-clicking `SideHeader` in `EditView`. Phase 3 says the commands are "moved from TapePanel". Phase 7 then deletes `SideHeader`. Side options has to include that one-recording case or rename disappears.
- Catalog drag behaviour in `CatalogView.move` is what Phase 13's "drag one down three places (four changes, the same number set)" describes. Typing is not. `commitTyping` stages that one tape, re-sorts, and does not touch the other reel. A taken number is refused later by `Library.checkRenumbering` (`CatalogError.duplicate` / `.taken`). Blank input calls `stage` with the original number, so it undoes typing. It does not clear a number. The new test "type a taken number (both reels change, a swap)" is new behaviour, and it disagrees with "Behaviour copied exactly from the view."
- `EditModel.leave()` clears `expandedLaneID` and stops the player. `EditView`, `SitePostView`, `CollectionView`, and Read Along notes all save or flush in `onDisappear`. A pending handoff or a `WorkPosition` saved from `onDisappear` will see a cleared selection and a stopped player if it runs after `leave()`.
- `EditModel.append` and the append confirmation dialog exist. There is no `appendTargets(for:)`. Adding one is fine. `expandedLaneID` currently toggles off when the open lane is clicked again. Phase 7 should keep that.
- Collection `saveAndWait` / `loadedID`, both delete wordings, and Send Changes gated on `hasUnsentChanges` are all in `CollectionView.swift`.
- Bring In is disabled when `trackCount == 0`, while a push is running, or while recording, and the progress text is "Track n of n" (`SitePostsView`, `PushModel.importEntry`).
- `joinCollectionOnSite` runs from the push finish path. Leaving it untouched is right.
- Menu commands are ⌘R, ⌘⇧I, and ⌘F (`RemanenceApp.swift`). The menu bar extra shows `pipelineSummary`. Dock drops call `AppModel.add`. The import banner and drop overlay are in `LibraryView`.

Phase 2's acceptance check is wrong. "Click through every sidebar item during a level check and confirm the meter is still live on return" does not prove the session survived. A level check is not `isRecording`, so `close()` cancels it and stops the input. Coming back runs `open()`, which starts a new listen at `.setup`. The meter is live because it was restarted. The check that matches the code is: start an actual recording, visit other sidebar rows, come back, and the take is still going. That check opens the microphone, and Phase 2 never mentions `scripts/dev/micuse.swift` or a go-ahead. Phase 10 does. CLAUDE.md applies to both.

## Hard rules

The file lists are right. Masters are written from `Recording.swift`, and also from `DropImporter.swift`, `BackupImporter.swift`, and `SiteImport.swift`. The catch-all "anything that writes under `masters/`" covers those. `AppDatabase.swift` migrations stop at `v13-collection-sync`. No phase should add one.

`-siteURL` really does override for one launch. `PushModel.siteURL` reads `UserDefaults.standard`, and the argument domain wins over the saved domain. Nothing writes `siteURL` back. Opening Recording calls `refreshSiteNumbers()`, opening Catalog does too (`CatalogView.task`), and opening Site Posts calls `loadListing()`. All three call `listEntries()` when a key is in the Keychain. The warning in section 3.4 is true. Reading `-libraryPath` from the argument domain only is the right constraint. `LibraryPaths` already takes an explicit library URL and keeps models in Application Support, so a scratch library does not need a second models folder.

Two claims in the hard-rule section are stronger than the code:

- `CollectionSync.pushCollection` catches `SiteError.changedOnSite`, loads the new clock, and sends the local collection again. The first conflict never reaches `collectionFailure`. A delete, or a second failure, does. Site Post shows `syncFailure` / `failure` via `error.localizedDescription`. Catalog shows `failure` from `renumber`. The rule "the error must still reach the screen" for a collection push would push someone to edit `CollectionSync.swift`, which section 1 forbids.
- `SiteEntry` has no `published` field, and `SiteClient` documents create as unpublished. `publishingIsSentOnlyWhenAsked` checks that an update omits `published` unless asked. `aPushCreatesAnEntryAndMarksTheTape` does not assert `published == false`. `CollectionsTests` does, for collections. The risk row "PushTests already assert drafts arrive unpublished" overclaims. The Phase 11 diff check (no new `setPublished(true)` except Publish reel) is the check that matters.

Phase 13's "nothing leaves the Mac" is false if a key is stored. `PushModel.renumber` skips `site.renumber` when no reel is pushed, then always calls `refreshSiteNumbers()`, which lists the live site. Scratch Apply is local only while `-siteURL` points away.

Section 1 says staged catalog changes may live in UserDefaults. Q13 and Phase 13 say they live in memory until Apply, Revert, or quit. Persisting them would offer a stale renumber on the next launch. Keep the Phase 13 rule.

`preferredColorScheme(.light)` and the 860 by 640 minimum are already in `RemanenceApp.swift`. The 900 by 692 check matches CLAUDE.md. `player.currentTime` is already read next to `preciseTime` in `ReviewView`. The Read Along `.fixedSize(horizontal: false, vertical: true)` sits inside a `ScrollView`, as Phase 9 says.

## Tests

The new core types are the right cut. `ShelfFilter`, time formatting, shelf status, work-position clamping, track handoff, site stage, collection footer counts, and catalog staging are all pure and belong in `RemanenceCore`. The existing suites named for Phases 6, 7, 10, 11, and 13 (`ReviewTests`, `TrackSpansTests`, `PushTests`, `RecordingTests`, `SidesTests`, `SitePostTests`, `SiteSyncTests`, `CatalogTests`, `CollectionsTests`, `TranscriptTests`) do cover markers, trims, append, order, push, and renumber at the library layer. A view rewrite that keeps calling those functions will not lose them.

Gaps:

- Phase 13's staging tests need expected results for blank input and a deleted tape, and they must not expect a typed number to swap the other reel.
- Handoff tests should build a `PostTrack` with `continuations`. Searching only the top-level array misses appended audio. `pieces` is the flat list.
- The zoom-restore flag and "apply the pending target once" live on `ReviewModel` and `EditModel`, which are app types. The core tests will not catch a second `observe` update clobbering them. Worth a sentence in the phase that says how the flag is consumed.
- There is no test that a fresh push's create body omits `published`. That is a one-line addition to `PushTests` if you want the risk row to be true. It is not a reason to edit `Push.swift`.
- `project.yml` has no app-target test bundle. Section 3.3 runs the same package tests as section 3.2, plus an app build. That is still worth running at the phases named. It does not cover navigation.

## Scope

In scope, and already marked as such: last-position memory (N1, also `docs/ideas.md` §11, but the mock approves it), Review-to-Edit handoff (N2, ideas §8), Import audio… (N3, the mock's button, wired to the existing `AppModel.add`), Setup in the sidebar (N5), Append to another track… (N6, the mock's menu; the confirmation text should stay the one in `EditView.appendMessage`, not the longer preview in ideas §9), Add reels… (N7), Save-now (N8), Approve for push (N9; the proposal, not a drawn pre-approval button), `-libraryPath` (Q22).

Out of scope, correctly excluded: marker key while recording, Listen Later, dropout times, alternate takes, photos while recording, undo in Edit, preview links. The stop screen should stay the mock ("Side A saved" and the four actions), not ideas §1's "6 markers · 2 dropouts" summary.

Invented, and should come out:

- Typing a taken catalog number swaps the other reel.
- Section 1 storing staged renumbers in UserDefaults.
- Any edit to `CollectionSync.swift` so the first clock conflict becomes visible. It is swallowed on purpose today.

`ShelfStatus` value "on the site (not yet read)" is a new label. Catalog today shows a pushed tape with no snapshot as "Draft" (`isPublished` is false when `SiteSnapshot.decode` fails). Put the new words in Q14 or keep "Draft".

## Phase size

Phases 0, 1, 3, 5, 6, 8, 9, and 10 are one screen or one extraction. Phase 7 is the dangerous one: `EditView.swift` is 941 lines of drag targets, focus, and trim handles (the plan says 940). Keeping `EditModel`'s save, play, split, trim, and order functions untouched is the right limit. Do not also change selection, append, or zoom in that same phase beyond what is listed.

Phase 11 (`SitePostView.swift`, 708 lines) is large but one screen, and the button table is the right way to hold it. Phase 2 is a real navigation change and is still one phase. Phase 14 is a bucket: Site Posts, search, setup, empty shelf, drop overlay, docs, and "remove anything left unused". The last of those can delete `TapeObject`, which Phase 5 still needs for the hero, or `TransportBar`, which Read Along still uses. Name the deletions.

## Risks the plan already has right

Live site via the Keychain, scratch library before any write, width at 900 by 692, `fixedSize` outside a `ScrollView`, Edit's gesture surface, two players, late `EditModel.observe`, zoom reset, keys routed on `route`, recording surviving navigation, `List.onMove` versus a custom table, snapshot decoding once per shelf update, Iowan falling back to sans if the name is wrong, and capture having no automated test. `native-app-plan.md` still has the Scarlett pass unfinished. Phase 10 rewrites the screen that pass will use. The controls have to survive, because that pass is still owed.

Additional risks:

- `refreshSiteNumbers()` after a scratch Apply, described above.
- Phase 11's "fake the progress with a debug value". `PushModel.progress` is `private(set)` and there is no debug hook (the old one was removed). A setter on `PushModel` is a way to poke the push path. Keep the fake in the view, for the layout check only.
- Phase 0 "before" pictures from a scratch library of three tones cannot show Published, Draft on site, transcripts, or a real collection. Say which screens those three files can actually open.
- Seeding "through the Dock route" will steal focus if it is a real Dock drag. `application(_:open:)` is the same function. Call that, or drop on the scratch window.

## Required changes

1. **Phase 1 font stack.** Use the mock and `proposal.md` stack: Iowan Old Style, Palatino Linotype, Palatino, Georgia, then generic serif. Q19 currently substitutes the system serif for Georgia.
2. **Phase 1 tokens and forwarders.** Map `Theme.card`, `Theme.board`, `Theme.inkMuted`, `Theme.accent`, `Theme.good`, and `Theme.attention` onto the section 4.1 tokens, or keep the old names as aliases. Keep `TimeLabel` and `ReviewTime.precise` as forwarders. `ReviewTime` is in `ReviewView.swift`. Moving it with no forwarder breaks the review screen, which Phase 1 says it does not rearrange.
3. **Phase 13 must copy `CatalogView` typing, not a swap.** `commitTyping` stages one reel. A taken number does not rewrite the other reel. Apply then fails with `CatalogError.taken` or `.duplicate`. Dragging is what deals one set of numbers out (`move`). Delete the test "type a taken number (both reels change, a swap)". "Swap two numbers" is display only, for the case the mock draws: exactly two staged reels, each given the other's current number. Blank input restores the original and does not clear it. A tape deleted while staged is removed from `order` and `staged`, so a later drag cannot deal a number that now belongs to nobody. Narrow "Behaviour copied exactly" to `move`, `stage`, `commitTyping`, `changes`, and `reset`.
4. **Answer the collection column in Q13.** Today's row shows the collection name (`CatalogView`, 190-point column). The default answers only the site column. Say whether the collection name stays.
5. **Section 1.** Staged catalog changes stay in memory until Apply, Revert, or quit, as Q13 says. Remove them from the UserDefaults sentence. Last position in UserDefaults is fine.
6. **Section 6 dependencies.** Replace the "only 5 needs 4 and 8 needs 6 and 7" line. Phase 12 needs Phase 4. Phase 8 needs Phase 5. Phases 5 and 6 both edit `ReviewModel.swift`. Phases 4, 5, 8, and 13 all edit `AppModel.swift`. Phases 9 and 11 both edit `ReadAlongView.swift`, in that order. Do not start those pairs together.
7. **Phase 9 and the Phase 11 button table.** Phase 9 must keep the approve control Phase 3 parked in the Read Along body. Add "Withdraw approval" to the Phase 11 table, calling `model.setApproved(tape, false)`. Today only `ReadAlongView` clears `approvedAt`.
8. **Phase 5 and Phase 8 versus `EditModel.leave()`.** `EditView.onDisappear` calls `leave()`, which nils `expandedLaneID` and stops the player. Save the work position, and read the handoff position, before that. Apply a pending Edit target once, when `observe` first has lanes, then clear it. `observe` keeps streaming. Walk `PostTrack.pieces` (the head plus `continuations`). A search of the top-level array does not find appended audio.
9. **Phase 2 microphone check.** Replace the level-check tour. While a recording is running, open other sidebar items and return. `close()` refuses only then. Run `scripts/dev/micuse.swift` first and get a go-ahead, as Phase 10 already requires. A level check opens the input too, and leaving it cancels the check.
10. **Phase 6 geometry and labels.** Overview stays about 58 points. The close-up may shrink to 110. It is 142 in the mock and has a minimum of 170 today. Trim buttons keep the I and O letters, because the mock footer does not. "Side options ▾" stays at the foot of the track column. Review's small line is the start time. The trailing number is the duration.
11. **Phase 7 duration, masters line, and single-side rename.** Edit rows show duration after the side ("Side A / 0:36" on Muted ending), not the start time Review shows. Keep a visible "masters never change" line. The mock puts it in the footer. `SideHeader` is the rename path for a tape with one recording. `TapePanel` only offers rename and delete when there are two or more items. Phase 3's Side options has to include that case before Phase 7 removes the heading.
12. **Phase 10 clock and advice.** The big clock uses `timecode` (`00:01:18`), not `TimeLabel.clock`. The badge text follows the mock: "Recording", then "Stopped". Must-still-work must include the six `record.advice` states in `RecordView.detail`. Clipping and too-quiet stay in the attention colour and on screen with Stop. Dropout, stall, disk, and input problem are additional lines, not a replacement. Add the meter colours `#292e29`, `#f4efdc`, and the recording dot `#de886c` to the token table.
13. **Collection conflicts and scratch Apply.** State in section 1 that `CollectionSync.pushCollection` absorbs the first `changedOnSite`, refreshes the clock, and sends again, so that error does not appear in the sheet. Do not change that file. In Phase 13, say that Apply on the scratch library still calls `refreshSiteNumbers()` when a key exists, so `-siteURL` is what keeps that read off the live site.
14. **Phase 14.** Name what gets deleted. Keep `TapeObject` and `TransportBar`. The Site Posts status for a row with no local tape is "Site only", from the dialog in `01-shelf.html`. Do not run that row through `ShelfStatus`.

## Suggestions

- Shelf, recording, and Site Post footers should use the mock's sentences, not only `pipelineSummary`. Q14 already keeps the word "Listening…" inside the shelf badge.
- Catalog subtitle, and a pending-column explanation that is the swap sentence only for a swap. Other counts can keep today's confirm copy ("Relabel the boxes to match.").
- Quote the collection note about the public page listing published reels only.
- Badge text stays ink. The mock colours only the 7-point dot. Draft gold `#9e8054` on paper is about 3.4 to 1, under 4.5. Muted `#696156` on paper is about 5.6 to 1, so the Phase 1 contrast check holds for that pair.
- Eyebrows are rust `#81533d`. Table headers and `.cap` labels stay muted. A single "eyebrow" style will paint "Tape label" and "Pending changes" rust.
- Hero title is 35px beside a picture that takes 36% of the hero, not the 49px page title. `.track strong` is 19px. Page padding in the mock is `clamp(25px, 3.35vw, 49px)`, not a hard step at 24 / 49.
- Q9 should say the other case too. On an up-to-date draft the mock's main button is Publish reel, with Update and Refresh beside it. Update is primary only when there are unsent changes.
- Add "on the site (not yet read)" to Q14, or keep today's "Draft" when `pushedAt != nil` and the snapshot is missing.
- Phase 11's pushing layout should be a view-local sample value, removed before the phase ends. `PushModel.progress` is not settable.
- Phase 0 screenshots should list the screens three local tones can open. Published, draft, and transcript states will not be among them. Seed by calling the open-file path, not by dragging onto the Dock.
- Correct the risk row to cite `SiteEntry` (no `published` field), `publishingIsSentOnlyWhenAsked`, and the collection test `state.published == false`.
- A small core type for "where Back goes" would lock the `routeBeforeReadAlong` bug the plan already found. App navigation itself has no test target.
- Keep `EditModel.toggleExpanded`'s collapse-on-second-click. Escape-to-whole-track is extra, and the mock does not remove the collapse.
- Section 3.3 does not add coverage beyond section 3.2. The scheme in `project.yml` only runs `RemanenceCoreTests`.
