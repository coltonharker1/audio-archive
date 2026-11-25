1. [minor] `Remanence/CollectionView.swift:452` — Reel titles now open Review on a single click, with a double-click and an Open menu item beside that. Phase 4's row behaviour is the shelf table; Phase 12 owns this file. `AppModel.swift:481` also treats Return as open whenever `route == .shelf`, which includes a collection.
2. [minor] `Remanence/TapePanel.swift:1` — `TransportBar` correctly moved to `TransportBar.swift`, but this file is still in the target as a comment that says to delete it.
3. [minor] `Remanence/LibraryView.swift:66` — An empty library shows `EmptyShelfView`, which never sets the shelf footer. After leaving and coming back, the status line falls through to `pipelineSummary` ("All caught up") instead of the blank shelf note in section 4.3. The note is only applied from `ShelfView.swift:85`.

VERDICT: PASS
