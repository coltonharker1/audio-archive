1. [blocking] `Remanence/CatalogView.swift:93` — `onMove` calls `commitAllTyping()` before `moveInCatalog`. That commit changes `order` before the drag indexes are used: a new number re-sorts the list, and clearing a number just given to an unnumbered tape removes it at `RemanenceCore/Sources/RemanenceCore/CatalogStaging.swift:86`. An index past the new end traps on `order[$0]` or `insert` at `CatalogStaging.swift:71`. An index that is still in range moves a different reel than the one dragged.

2. [minor] `RemanenceCore/Sources/RemanenceCore/CatalogStaging.swift:84` — Blanking a numbered reel drops its staged number and leaves `order` where the temporary number had sorted it. While any other change is still staged, `follow` keeps that order, so the list is no longer by RA number, and a later drag deals the sorted numbers onto it. Typing the reel's own number re-sorts at line 95. The blank test never checks `order`.

VERDICT: CHANGES
