# Recent work, November 2026

What was built across the app and the site between 2026-11-23 and 2026-11-24, why,
and how the pieces fit. For the project's overall status and plan, see
[native-app-plan.md](native-app-plan.md). For ideas not yet built, see
[ideas.md](ideas.md).

Two repos are involved:

| Repo | What it is |
|---|---|
| `coltonharker1/audio-archive` | This one: Remanence, the Mac app |
| `coltonharker1/remanence-archive` | The site, remanencearchive.com (Next.js on Vercel, Neon Postgres, R2 storage) |

The app is where everything is written. The site shows what the app pushes. The rules
that hold throughout:

- **Masters are never changed.** Splits, trims, speed, level, reversal and appends are
  all stored as settings, and applied only to the copies made when pushing.
- **Pushes arrive as unpublished drafts.** Nothing is public until Publish.
- **Every edit sent to the site is checked against its clock.** If the site changed
  since the app last read it, the change is refused rather than overwriting.

---

## Tidying the site's catalog

The site had two stray posts at RA-008 and RA-009, both made by the old Go app. They
were deleted through the app's delete route, so newly recorded tapes could take those
numbers: School Of Accordian became RA-008, and Donahue Promos RA-009. Before
anything was deleted, the old RA-008's audio was saved, checksummed, to
`~/Music/remanence-ra-008-originals/`.

## Sides

- **Delete Side** and **Rename Side** (right-click a side in the tape panel). This
  covers re-recording a botched side as a new one: delete B, then rename C to B.
  Deleted audio goes to the Trash.
- **Re-record Side X**, offered right after a side finishes, for when you realise
  straight away that the take was bad.
- A side's file name is never reused, so a renamed or re-recorded side can never
  overwrite another side's master.

Code: `RemanenceCore/.../Sides.swift`, `Recording.swift`, `RecordModel.swift`.

## Edit mode

Edit shows every track of a tape as its own lane.

- **Level, speed and direction** for each track, heard straight away. Speed fixes
  tapes recorded at the wrong speed.
- **Zoom:** open a track up to see its waveform close and split it precisely. Use
  pinch, − and =, or swipe.
- **Split** at the playhead with M. It snaps to the nearest quiet moment unless Option
  is held.
- **Append:** drag a track onto another and it plays as part of that track on the
  site. It's pushed as one file, joined sample for sample, and each piece keeps its own
  settings.
- **Reorder:** drag a track between two others, or use Move Up and Move Down. The site
  shows tracks in this order.
- **Rename:** double-click a track's or side's name.
- **Trim:** drag the handles at either edge of a track's waveform. The trimmed parts
  stay visible but dimmed, so a trim can be pulled back. Review's own I and O trim a
  whole side, and are labelled so.
- **Scrubbing:** dragging across a waveform, or dragging a trim handle, plays the
  audio like a reel rocked by hand. Slow drags play slow and low, fast drags play fast
  and high, and dragging back plays backwards. Review has it too.

Code: `Remanence/EditModel.swift`, `EditView.swift`, and in the core
`Appending.swift`, `Markers.swift` (trims), `TrackPlayer.swift` and
`TapeScrubVoice.swift`.

## Collections

Reels from the same box, grouped and written up together. The design, including
Codex's proposals and mockups, is in [collections/](collections/README.md).

**In the app**
- **Sidebar:** a Collections section with New Collection. Drag a tape from the shelf
  onto a collection to add it.
- **Collection screen:** the name, where and when found, the write-up, photos with
  captions, and the reels, dragged into the order they should appear in.
- **Recording:** a Collection picker, including "New Collection…". Recording while a
  collection is open picks that collection.
- **Shelf:** each tape's right-click menu has a Collection submenu.
- **Where and when found:** a reel with its own blank uses the collection's, in Site
  Post and when pushed.
- **Site panel** on the collection screen:
  - Push to Site sends it as a draft.
  - Send Changes appears only when something here differs from what was sent.
  - Publish and Unpublish, plus Remove from Site in the ⋯ menu.
  - Pushing a reel that's in a collection already on the site sends the collection
    again, so the reel joins it there.

**On the site**
- `/collections/[slug]`: the contact sheet of photos, the write-up, and the reels
  in the owner's order.
- The index's **By RA number · By collection** switch.
- Reel pages: "From the collection …", with Previous and Next.
- Only published collections are shown, and they list only published reels.

**Data**
- App: `collection` and `collection_image` tables; `tape.collection_id` and
  `collection_position`; the site's state on each collection.
- Site: a `collections` table, plus `sounds.collection_id` and `collection_position`
  (`drizzle/0003_collections.sql`, applied 2026-11-24).
- Routes: `GET`/`POST /api/sync/collection` and `/api/sync/collection/delete`.

Code: `Collections.swift`, `CollectionSync.swift`, `Remanence/CollectionView.swift`.
On the site: `src/lib/collections.ts`, `src/lib/sync-collections.ts`,
`src/app/collections/[slug]/page.tsx` and `src/components/index-list.tsx`.

## Catalog numbers

**The problem:** the site gave each post its RA number when it was first pushed, so
pushing tapes out of order left the labels on their boxes wrong.

**The fix:** the app gives the number instead.
- **When recording:** the recording screen shows "This tape will be RA-013" before
  Record. Pressing Record gives the tape that number, and the screen then says to
  label the box with it.
- **When adding files:** tapes dropped into the app get their number on arrival.
- **Which number:** the lowest one that's free, here or on the site. A tape deleted
  before it was pushed frees its number again.
- **When pushing:** the app asks the site for the tape's number. If another post
  already has it, the push is refused with a message, instead of quietly using a
  different number.

**The Catalog** (the # button in the toolbar) lists every reel by number.
- Drag a reel to a new place and the numbers follow the order. Or type a number.
- Apply changes everything at once, on the site first for reels that are there, so
  two reels can swap numbers.
- A published reel's old address redirects to its new one. Files are stored by
  content, so nothing is uploaded again.

**Site routes:** `/api/sync` takes an optional `catalogNumber`, and
`/api/sync/renumber` swaps numbers in one transaction. Renumbered posts keep their
old numbers in `metadata.former_catalog_numbers` for the redirect.

Code: `RemanenceCore/.../Catalog.swift`, `Remanence/CatalogView.swift`. On the site:
`src/app/api/sync/renumber/route.ts` and `src/lib/sync.ts`.

## Working with Codex

Codex's CLI, which runs OpenAI's Astra model, did the collection page design. It ran
read-only in the site's repo, so it could match the existing design without changing
anything. The CLI was updated to 0.172 to use that model. Its briefs and answers are
in [collections/](collections/README.md). An earlier set of UI/UX suggestions from
Codex is in [ideas.md](ideas.md), with notes on each.

## Testing

**App:** 329 tests in `RemanenceCore`. New suites cover sides, appends, track order,
trims, collections, collection pushes against a fake site, catalog numbers and
renumbering, and the scrub voice's motion. The fake site (`FakeSite` in
`PushTests.swift`) behaves like the real routes, so nothing touches the live site in
tests.

**Site:** 37 tests in `src/lib/*.test.ts`, for the collection and renumbering rules.
The pages were checked in an offline mock mode of the site, never against
production.

## Still to try or build

- **Untried on the real site:** pushing and publishing a collection, and
  renumbering a published reel.
- **Preview before publishing:** a private link to a draft reel or collection on the
  real site. It's planned in [ideas.md](ideas.md).
- **Undo in Edit**, and the rest of the editing ideas in [ideas.md](ideas.md).
- **UI tweaks** to collections, which the owner has in mind.
