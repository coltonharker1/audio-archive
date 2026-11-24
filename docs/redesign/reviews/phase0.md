I'll review Phase 0 against the plan, the mocks, and the staged diff, without changing anything.

Phase 0 matches the plan. A normal launch still opens `~/Music/Remanence` and never reads the argument domain. `-libraryPath` is taken only from that domain, and only as an absolute path. A missing or relative value shows an error and does not open the real database. `-siteURL` still overrides for that launch. No core, push, or view changes, and no new tests were required. The recorded baseline matches the tree: 329 `@Test` functions and 35 suites. The noted `spawnedToolsRunAtUserInitiatedPriority` failure is in `SubprocessTests.swift`, which this diff does not touch, and the note says it failed before the change as well.

No findings.

VERDICT: PASS
