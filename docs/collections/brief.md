# Design brief: Collections on Remanence Archive

You're in the repo for remanencearchive.com, a Next.js site that publishes digitized
reel-to-reel tapes. Each tape is a post with an RA number (RA-001, RA-002…), a title,
a description, a medium, where and when it was found, an estimated recording date,
photos, and one or more audio tracks. The `sounds` table in `src/db/schema.ts` holds
the posts. The pages are under `src/app`.

**This is a design task only. Don't change, create or delete any files, and don't
open `.env*` files.** Read the existing pages, components and `globals.css` so your
design fits the site's current look: its type, colors, spacing and tone. Some files
there have uncommitted work in progress. Read them, but don't touch them.

## The idea

The owner often gets a whole box of reels from one unknown person, such as a box
from an old network cable technician: sound effects, jingle snippets, talk-show
fragments. Taken together, a box sketches the character of whoever kept it.
A **collection** groups the reels from one box.

Decided so far:
- A reel belongs to at most one collection. Many reels are in none.
- The owner names each collection and writes it up however they like. It never
  names the real person, who is usually unknown.
- Collections grow over time: when a new reel is transferred, it's added to one.
  There are no placeholders for reels not yet transferred.
- A collection has a name, a write-up (a short essay), photos (the box as it
  arrived, labels), where and when it was found, and its reels.
- Reels keep their RA numbers. A collection has its own address, like
  `/collections/the-cable-man`.
- A collection is a draft until published. Its page lists only public reels, so a
  box can go live while still being transferred.

The owner's starting sketch for the site:
1. The index can list reels by RA number, as it does today, or by collection.
2. A reel's page has a way to go to its collection.
3. A collection page shows the write-up, maybe a photo of the box, and every reel in
   it, each linking to that reel's page.

They're open to better ideas.

## What to send back

1. **A design proposal** in prose and bullets, covering:
   - the collection page: layout, its hierarchy, how reels are listed, what each
     reel shows, and how audio previews might work;
   - the index's by-collection view and how you switch between views;
   - how a reel's page shows that it belongs to a collection, including moving to
     the previous and next reel;
   - empty and edge cases: a collection with one reel, a reel in no collection, a
     write-up that's very long or missing, no photos;
   - phone layout;
   - anything you'd add or change in the owner's sketch, and why.
2. **A mockup of the collection page** as one self-contained HTML file in a single
   ```html fenced block: inline CSS, no external scripts, realistic sample content
   for the network-cable-technician box (5–7 reels), matching the site's existing
   style as closely as you can.
3. **A mockup of the index's by-collection view** as a second ```html block, in the
   same way.

Keep the proposal concrete, and point out where you're guessing about the existing
design.
