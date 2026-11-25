Reviewer: grok-4.7-build-fast (Grok balance restored), reviewing commit 500a1a0, which Claude Opus had reviewed in Grok's place.


The commit only touches the Shelf hero title wrap and a review note. I'll read the diff against the plan, mocks, and prior reviews.

The hero change sits between the visual follow-up and the inspector commit. I'll read the surrounding Shelf code, the mock, and the implementer notes.

The Shelf hero title fix in `500a1a0` is correct. A two-line compact title now gets tighter spacing through `ViewThatFits`, and the 150-point hero height stays fixed. Nothing in the commit touches masters, drafts, the site, or stored data.

Iowan Old Style Roman at 26 pt has a line height of 35.50 pt, so two lines are 71 pt. The tight column drops the title padding from 6 to 2 and the space above Resume from 12 to 6, saving 10 pt against a column that was about 1–2 pt over 150. That lands near 140–144, inside the fixed height. A one-line title, and any title in the 212-point regular hero, still gets the original spacing. Only one column is installed, so the header trait, the Resume label, the tooltip, and the collection link stay as they were. The hero height is unchanged, so the rows under it do not move.

1. [minor] `Remanence/ShelfView.swift:198` — The 900×692 long-title check from the plan has not been seen on screen. The font metrics say the tight column fits, with several points to spare. If a rendered column is still taller than 150, `ViewThatFits` keeps that tight column and the title can fall back to one line with an ellipsis, which is the old behavior.

VERDICT: PASS
