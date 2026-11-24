# Collections: design notes

A **collection** groups the reels that came in one box, so together they sketch whoever
kept them. Examples include a box from a cable-network technician (sound effects, jingles,
talk-show fragments) and a set of accordion lesson reels. This folder holds the design
work done before building collections in November 2026.

## Files

| File | What it is |
|---|---|
| [brief.md](brief.md) | The first brief given to Codex: what collections are and what was already decided |
| [codex-proposal.md](codex-proposal.md) | Codex's answer: the collection page, the index by collection, reel pages, edge cases and phones |
| [collection-page.html](collection-page.html) | Codex's first collection page mockup, with one lead photo |
| [index-by-collection.html](index-by-collection.html) | Codex's mockup of the index grouped by collection, with working search and the view switch |
| [photos-brief.md](photos-brief.md) | The follow-up brief, asking how to show several photos of a box |
| [codex-photos-proposal.md](codex-photos-proposal.md) | Codex's comparison of a contact sheet and a print strip |
| [photos-contact-sheet.html](photos-contact-sheet.html) | **The chosen layout:** photos as a contact sheet beside the write-up |
| [photos-print-strip.html](photos-print-strip.html) | The alternative: a scrolling strip of photos below the write-up |

The mockups are self-contained HTML. Open them in a browser. Their photos are drawn
stand-ins, and the sample collection, "The Cable Man", is invented.

## What was decided

- **A reel is in at most one collection.** Themes that cut across boxes could become
  tags later.
- **The owner names and writes up each collection freely.** It never names a real
  person, who is usually unknown anyway.
- **No placeholders.** A collection grows as reels are recorded into it or added later.
- **The owner sets the order of reels.** The collection page and the index's
  collection view follow it. The index by RA number stays in number order.
- **Photos use the contact sheet:** three across beside the write-up, two across on a
  phone. Each opens the photo viewer. One photo is shown larger on its own.
- **Where and when found** belong to the collection. A reel uses them unless it has
  its own.
- **The address follows the name** (`/collections/the-cable-man`) until the collection
  is published. After that it stays fixed, so links keep working.
- **A collection is a draft until published.** Its page lists only published reels,
  so a box can go live while it's still being transferred.

## What was built

The **site** got the following:
- `/collections/[slug]`, built from the contact-sheet mockup.
- The index's **By RA number · By collection** switch (`?view=collections`).
- "From the collection …" on reel pages, with **Previous / Next** within the
  collection.
- The sync routes `/api/sync/collection` and `/api/sync/collection/delete`.

The **app** got these:
- A Collections section in the sidebar.
- A collection screen with the name, write-up, where and when found, photos, reels in
  order, and Push, Publish and Unpublish.
- A Collection picker when recording.
- A Collection menu on each tape on the shelf.

See [../recent-work.md](../recent-work.md) for how it all fits together.

## Still open

- Whether one photo can be marked as the lead, taking the full top row.
- What happens past about nine photos: show six and a "Show all"?
- Whether the shelf in the app should group by collection, or only the sidebar.
- A preview of a draft collection before publishing (see [../ideas.md](../ideas.md)).
