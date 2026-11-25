Reviewer: Claude Opus (`claude -p --model opus`, a fresh read-only session separate from the implementer), in place of grok-4.7-build-fast because the Grok Build usage balance ran out (HTTP 402).

## Shelf hero title fix: review

The staged change in `Remanence/ShelfView.swift` should fix the problem. It moves the hero's text column into `textColumn(isTight:)` and shows it through `ViewThatFits(in: .vertical)`, normal spacing first and tight spacing second. The second layout only takes over when the normal one doesn't fit the fixed 150-point compact hero.

- **Why it should work:** `ViewThatFits` measures each layout at the real width with no height limit. With `lineLimit(2)`, a long title measures at two lines, so the normal layout is too tall and the tight one is chosen.
- **Room to spare:** the tight layout uses 8 points of spacing instead of 18, saving 10 points. The fixer says the old layout ran 1–2 points over.
- **Nothing else changes:** short titles, and every title in the regular hero, still get the normal layout, which matches mock 01. The hero stays 150 / 212 points as in the plan's table, so the rows below don't move and the "six rows visible" check isn't affected.
- **Nothing lost:** only one layout is drawn at a time, so VoiceOver doesn't hear the title twice. The header trait, the Resume label, `.help` and the collection link are all kept.
- **CLAUDE.md:** no `.fixedSize(horizontal: false, vertical: true)` on the title, the existing `.fixedSize()` on the time label stays, and nothing touches audio, masters, the site or data.
- **Scope:** only `ShelfView.swift` changed, with no other edits mixed in. Not adding tests is reasonable for a layout-only change.

### Findings

1. [minor] `Remanence/ShelfView.swift:198` — No one has seen the fix on screen yet. The plan's Phase 5 check asks for the hero with a long title at 900 by 692. The fixer couldn't launch the app, and I can't either in this read-only session. If the serif's line height is larger than the fixer measured, even the tight layout won't fit, and the title will drop to one line with an ellipsis, the same as before. Nothing breaks in that case, but the 900 by 692 screenshot with a long title still needs taking before this is called done. If it still shows one line, tighten the spacing in the tight layout further.
2. [minor] `Remanence/ShelfView.swift:170` and `:183` — In the regular hero, the tight layout jumps from 7/17 points of spacing to 1/6, which is a big visual change. A two-line title should fit 212 points easily (roughly 184 at mock sizes), so this shouldn't happen in practice. A scaled step such as `size == .regular ? 3 : 1` would be safer if it ever did. No change is needed now.
3. [minor] `Remanence/ShelfView.swift:198-200` — The code comment and the fixer's notes describe the tight layout as "for a title that wraps". Strictly, it's used whenever the normal layout is too tall, whatever the reason. Only the title can wrap in practice, because the subtitle has `lineLimit(1)` and `.fixedSize()` on its details, so this is wording only.

VERDICT: PASS