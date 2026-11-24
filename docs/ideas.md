# Ideas

Proposals for later. Nothing here is planned or started. They came from an outside
UI/UX review on 2026-11-23, with notes on what the app already does. Every idea has
to keep masters read-only, edits non-destructive, and pushes as unpublished drafts
until Publish.

## Suggested order

1. Undo in Edit (#10)
2. The side-saved summary, with M markers, timed dropouts and Listen Later flags
   (#1, #3, #4, #5)
3. Edit this track from Review (#8)

## Recording at the deck

### 1. A summary when a side stops
Show something like "Side A saved · 32:14 · 6 markers · 2 dropouts", with Record
Side B and Review Side A just below. Move Re-record into a secondary menu, and add
Finish This Reel to go back to the shelf.
- Open question: should the main button be "flip the reel" or "listen back first"?

### 2. A Large Meter readable from the deck
Large Meter already exists, and so does Keep Recording when the app thinks the tape
has ended. Check whether the side, elapsed time and input status can be read from a
few feet away. Keep the remembered machine setup note.

### 3. One key for track markers while recording
There's an Add Marker button with a count, but no key for it. Bind M, as in Review,
and briefly show "Marker 4 · 12:38" as confirmation. Small.

### 4. Listen Later flags
One key flags a splice, a station ID, a speed change or a name to look up. A note is
optional. Review lists the flags and plays from a few seconds before each one. Store
them apart from markers so they never change where tracks split.

### 5. Dropouts you can act on
Today the app only counts dropouts and says to listen afterward. Save when each one
happens, put the count in the side-saved summary, and let me play each spot while the
reel is still on the deck. They can share the Listen Later list, marked as detected
rather than flagged by me.

### 6. Alternate takes of a side
Re-record moves the old take to the Trash. The proposal keeps both takes under the
same side, lets me compare passages, and lets me pick which take each track uses.
- Concern: this is a big change, since markers would have to be kept in step across
  takes. Delete Side and Rename Side already handle the common case.
- A cheaper middle ground: keep the old take hidden until I've heard the new one and
  confirmed it, instead of trashing it right away.
- Build the full version only if re-recording becomes common.

### 7. Photos while recording
Add photos of the box, leader, labels or track sheet from the recording screen. Site
Post already has photos.
- Concern: choosing which photos are public would need a per-photo private flag,
  which the site doesn't have yet.

## Reviewing and editing

### 8. From Review to Edit
Add "Edit this track" to Review's track list. It opens Edit at the passage I was
hearing, and coming back restores the marker, playhead and zoom. Keep the whole-side
waveform, close-up, quiet-point snapping and Hear the Join.
- Skip renaming Review and Edit to "Mark tracks" and "Edit tracks". Relabeling
  Review's trims as Trim Side Start and Trim Side End fixed the real confusion.

### 9. Telling reorder and append apart
Keep dragging for both: drop between tracks to reorder, onto a track to append. That
was chosen on purpose. Optionally add "Append to Another Track…" in the ⋯ menu.
Before appending, show the resulting order and total length, like "Interview, part
1 → Interview, part 2 · 18:42".

### 10. Undo in Edit
⌘Z for split, join, append, reorder, trims, and level, speed or direction.
- Review already has an undo stack to reuse.
- The hard part: undoing a join has to restore the second track's name,
  description, settings, order and trims. A join deletes them along with the
  marker, so they must be saved before it.

### 11. Resume a review from the shelf
Offer "Continue Side B at 23:41", which restores the side, selected track, playhead
and zoom, for long reels reviewed over several sittings. Small.

## Preparing the site entry

### 12. Preview the entry, and clearer push buttons
- Replace Looks Good with Preview Archive Entry: hear the tracks in site order and
  see the titles, descriptions and photos in place.
- Rename Push to Site to Create Unpublished Draft, and keep Publish as the step
  that makes the entry public.
- Check first what the site does with a post's first push before renaming.
- The full preview is a bigger job. For now, Site Post plus the site's unpublished
  page covers it.

## Collections

Group reels that came from the same box, so the box reads as a portrait of whoever
owned it. Talked through on 2026-11-23. Not started.

### Decided
- **A reel is in at most one collection.** Themes that cut across boxes, like
  jingles, could be tags later. They aren't collections.
- **Collections are named and written as I choose.** There are no fields for a real
  person. I usually don't know the owner, and wouldn't publish their name if I did.
- **No placeholders for reels not yet transferred.** A collection grows as reels
  join it.
- **Choose the collection when recording.** The new-tape screen gets a Collection
  picker, with an option for a new collection. A reel already in the library can be
  moved into a collection or taken out of one.
- **On the site:**
  - The index lists by RA number, as it does now, or by collection.
  - A reel's page links to its collection.
  - A collection page shows the write-up, photos of the box, and every reel in it,
    each linking to its own page.

- **Order:** I set the order of reels in each collection, and the collection page and
  the index's by-collection view follow it. The RA-number view stays in RA order.
- **Look:** follow Codex's proposal and mockups in `docs/collections/`.
- **Photos:** a contact sheet beside the essay (`photos-contact-sheet.html`): three
  across with short captions, two across on a phone, and each one opens full size.
  Not the print strip.
  - Open: should one photo be able to lead, taking the full top row?
  - Open: past about nine photos, should the page show six plus "Show all"?

### Proposed details
- **What a collection holds:** name, write-up, photos of the box, and where and when
  it was found. Its reels take where and when found from the collection, and a reel
  can still override them.
- **RA numbers never change.** A collection gets its own address, like
  `/collections/the-cable-man`.
- **Publishing:**
  - A collection is a draft until it's published, like a post.
  - Its page lists only reels that are public, so it can go live with half the box
    still to do.
  - A reel shows its collection link only once the collection is public.
- **Site index:** the RA-number or collection view lives in the address
  (`?view=collections`), so it can be linked. The RA-number view could show each
  reel's collection as a small label.
- **Reel page:** "Part of *Collection*", with previous and next reel in that
  collection.
- **App shelf:** can group reels by collection. A collection screen edits the
  write-up and photos and lists its reels.

### Preview before publishing
See a reel or collection exactly as it will look on the site before making it
public: Push, then Preview, then Publish.
- **Today:** a push creates an unpublished entry, but reel pages show only
  published entries, so a draft can't be seen.
- **The link:** the app gets a short-lived signed link from the site, like
  `/archive/RA-010?preview=…`, signed with the sync key, lasting about an hour,
  hidden from search engines and never cached. It opens in a window in the app or
  in the browser.
- **The page:** the real page, with its audio, photos and essay, under a "Preview ·
  not published" banner.
- **A collection preview** also shows its draft reels, marked as drafts.
- **Why the real site:** a copy drawn in the app would drift from the site's design.
- **Site changes:** a route for preview links, and preview support on the reel and
  collection pages. The reel preview doesn't depend on collections and could
  come first.

### Order of work
1. In the app: collections in the library, the picker when recording, shelf
   grouping, and the collection screen with its write-up and photos.
2. On the site: a `collections` table and a link from each post (`sounds`) to its
   collection, the collection page, the index toggle, and the reel page link. Then
   a sync endpoint so the app can push collections. Deploying changes production,
   so confirm each time.
3. Later: tags, and playing a whole collection.

### Open
- What the collection page should look like, beyond a write-up, box photo and list
  of reels.
- Whether the shelf groups by collection always, or only as a view option.

## Editing like other audio editors

Suggestions from going through every Edit action, 2026-11-24. Undo (#10 above) comes
first; with it, Join no longer needs a confirmation. Append keeps its confirmation,
since I asked for it.

### First pass: make trimming solid
- **Hear the audio while scrubbing.** I asked for this one. Dragging across a
  waveform plays what's under the pointer, even while paused, in Edit and in
  Review. Neither does this today: Review's `scrubLive` only moves the playhead.
  - Start by playing short grains: about 60 ms from the pointer, with a few
    milliseconds of fade, using the track's level and speed. Drag left and they
    play backwards.
  - A tape-style version, where the speed follows how fast you drag, like rocking
    the reels by hand, could come later.
  - Where the drag ends becomes the playhead. If it was playing, it carries on from
    there.
- **Short automatic fades at every cut.** A few milliseconds on each trimmed or
  split edge, so cuts don't click. Optionally, a handle at the top corner of each
  edge to drag out a longer fade. Fades apply only to the pushed copy.
- **A time readout while dragging a handle:** "Start 0:03.42", and "Kept 4:12".
- **Hear the edit on release:** play two seconds from the new start, or up to the
  new end.
- **Snap trims to quiet,** as splits do. Hold Option to place them freely.

### Keys
- J K L shuttle in Edit, as in Review. Return jumps to the start of the track.
- ⌘= and ⌘− to zoom, ⌘0 for Whole Track, and Option-scroll to zoom.
- Click a handle to select it, then nudge it with ← and → (10 ms; 100 ms with Shift).
- **A selected track:** clicking a track selects it, and keys act on that track
  instead of whichever played last.
- Keep M for split, to match Review. Maybe add ⌘K as well.

### Bigger
- **Delete a range from the middle of a track:** drag across it and press Delete.
  The track keeps a list of ranges to skip, and the master stays whole.
- **Speed presets for tape:** ¼×, ½× and 2× alongside the slider.
- **Normalize:** "Set peak to −1 dB", using the measured true peak.
