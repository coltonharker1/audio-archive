1. [blocking] `Remanence/TapeWorkspaceView.swift:253` — `ForEach(Route.tapeTabs, id: \.self)` requires `Route` to be `Hashable`. `Route` is only `Equatable` at `Remanence/AppModel.swift:14`, so the tab row fails to build.
2. [minor] `Remanence/TapeWorkspaceView.swift:76` — The eyebrow joins the catalog number, the medium, and the era, and shows "Tape" when all three are missing. The phase and mocks 03, 04, and 07 show the RA number and medium only, as in `RA-019 / 5″ reel-to-reel`.
3. [minor] `Remanence/SitePostView.swift:185` — A tape that is not on the site is labelled "NOT ON THE SITE YET". That line was "SITE POST · NOT ON THE SITE YET". The phase keeps these bodies otherwise unchanged.

VERDICT: CHANGES
