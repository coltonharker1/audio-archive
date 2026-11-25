Reviewer: Claude Opus (`claude -p --model opus`, a fresh read-only session separate from the implementer), in place of grok-4.7-build-fast because the Grok Build usage balance ran out (HTTP 402).

I found nothing blocking in commit 97354f9. All six fixes match the mocks and the plan, and the one partial skip is justified. Nothing in the commit touches masters, the database, site pushes, the live site or audio, so no hard rule is at risk. I read the code only; nothing was built or launched.

**Item by item:**
- **Recording toolbar button (`RecordView.swift:55`):** It now uses the app's own pale button and hides the toolbar's glass backing, as the breadcrumb already does. It still dims only when disabled (`DesignSystem.swift:334`), and its label and tooltip are unchanged.
- **Shelf hero title (`ShelfView.swift:173`):** It now wraps to two lines at both sizes and doesn't use the `fixedSize` trap. My rough sums say it fits: about 139 of the compact hero's 150 points, and about 176 of the regular hero's 212.
- **Edit inspector (`EditView.swift:826`):** It now matches mock 04: Track actions, a rule, the drag hint, then "Return to Side A" with no rule between them. The hint still shows only when a track is selected.
- **"Post photograph" heading (`SitePostView.swift:759`):** It matches the mock's 21 px heading and Recording's "Capture settings" (21 pt, or 17 pt when compact).
- **Search breadcrumb (`LibraryView.swift:104`):** The recursion can't loop, because `routeAfterSearch` never returns `.search`. Making that property readable only exposes it; behaviour is unchanged.
- **Shelf row and Back crumb:** The fixer found that real clicks already work, so changing the code only for accessibility was the right call.

**Findings**

1. [minor] `Remanence/EditView.swift:826`: Pinning the drag hint at the foot takes about 60–70 points from a scroll area the notes put at about 360 at 900×692. That makes the skipped part of item 4 (Track actions out of view) a bit worse. It matches the mock, and nothing is lost because the actions still scroll, but it's worth judging on screen.
2. [minor] `Remanence/SitePostView.swift:759`: The new heading copies the private `columnTitle(_:size:)` helper in `RecordView.swift:734` instead of sharing it. The two can drift apart.
3. [minor] `Remanence/LibraryView.swift:148`: `.accessibilityAddTraits(.isButton)` on a `Button` does nothing, since a button already has that trait. The real accessibility gain is the `.contain` grouping at `LibraryView.swift:162`.
4. [minor] `Remanence/LibraryView.swift:104`: Search crumbs from a collection, such as "Collections / <name> / Search", have no mock behind them. The breadcrumb can now be three crumbs wide, but long names are shortened to 24 characters, so width is bounded. This wording is the fixer's choice and needs the user's sign-off.
5. [minor] Process: none of these layout changes has been seen at 900×692, as the plan requires. The independent review never ran either: `docs/redesign/reviews/followup-visual.md` records the Grok 402 error. Both are still to do, but neither is a code defect.

VERDICT: PASS