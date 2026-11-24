# Brief: redesign the Remanence Mac app

## The ask (from the owner)
"Help me redesign the audio archive app so that it is more intuitive, has better flow,
and feels like a sibling to the website (remanence archive)."

You are doing the UI design. Produce mockups the owner can approve before anything is built.

## Study first (read only)
- This repo (the SwiftUI Mac app "Remanence"): `CLAUDE.md`, `README.md`, `docs/DESIGN.md`,
  `docs/native-app-plan.md`, `docs/ideas.md`, `docs/recent-work.md`, `docs/collections/`
  (your earlier proposals and mockups for the site's collections), and the Swift source in
  `Remanence/` (AppModel, LibraryView, ShelfView, TapePanel, RecordView/RecordModel,
  ReviewView/ReviewModel, EditView/EditModel, CollectionView, CatalogView, PushModel,
  SitePostView/SitePostsView, SearchResultsView, SetupView, ReadAlongView) and `RemanenceCore/`.
  Work out the current screens, navigation and flows as they really are.
- The site: `/Users/colton/code/me/web/remanence-archive` (Next.js, remanencearchive.com).
  Study its visual language in `src/app/globals.css`, `src/app/layout.tsx`, `src/app/page.tsx`,
  `src/app/recordings`, `src/app/collections`, `src/app/archive`, `src/components/*`:
  typography, colours, spacing, layout, components, tone of copy.

## What to design
A redesign of the app that is more intuitive, with better flow between:
recording -> the shelf/library -> tape/side review -> Edit mode -> collections ->
the Catalog -> pushing/publishing to the site. It should feel like a sibling of the site
(shared type, colour, rhythm and vocabulary) while still being a proper macOS app.
Keep the existing features; fix the flow, wayfinding and hierarchy. Note where a step is
confusing today and how the new design fixes it.

## Deliverables (write ONLY into `docs/redesign/`)
1. `docs/redesign/proposal.md`: short. The main flow changes and why, the sibling
   design language (type, colours, components borrowed from the site), and a list of
   the mockups with one line each.
2. Self-contained HTML mockups, one per key screen, roughly 5 to 7, for example:
   `01-shelf.html` (main window / shelf / library), `02-recording.html`,
   `03-tape-review.html` (tape detail / side review), `04-edit.html`,
   `05-collection.html`, `06-catalog.html`, `07-push-publish.html`.
   Each shows a macOS window about 1440x900 (window chrome included, body at 1440x900
   viewport), with realistic sample content drawn from the docs (RA numbers, reel names,
   sides, collections). Inline all CSS; no external network assets (no web fonts from
   CDNs, no remote images; use system font stacks, inline SVG or CSS shapes for imagery).
   They will be screenshotted at 1440x900 in headless Chromium, so keep each screen's key
   content within that frame.

## Rules
- Do not change any source code or any file outside `docs/redesign/`.
- Do not commit, push, or run git commands that change state.
- No network access needed.
