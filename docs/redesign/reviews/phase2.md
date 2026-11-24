1. [minor] `Remanence/AppModel.swift:143` — While search results are up, the sidebar highlight always falls through to Shelf or a collection. Clearing the query returns to Catalog, Site Posts, or Setup (`routeAfterSearch` at line 532), but the highlight shows Shelf, and clicking that row calls `leaveToShelf()` and drops the return path.
2. [minor] `Remanence/CatalogView.swift:47` — Staged renumbers live in this view’s `@State`, and `.task` calls `reset()` on every appearance. Search or any other sidebar destination removes the view, so the staging is gone on the way back. The old sheet kept it until Done. Section 1 and Q13 say it lasts until Apply, Revert, or quit; that hoist is Phase 13, and nothing is written before Apply.

VERDICT: PASS
