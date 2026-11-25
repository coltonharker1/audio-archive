Reviewer: Claude Opus (`claude -p --model opus`, a fresh read-only session separate from the implementer), in place of grok-4.7-build-fast because the Grok Build usage balance ran out (HTTP 402).

I've read the staged diff, the earlier review and the fix notes. Here is the review.

## Summary

The re-layout is still staged and uncommitted. The fixes cover the earlier blocking finding and the minor ones:

- **Space:** the heading's top inset and the 5 pt under Return are gone. That takes back about 11 pt, so the worst case (a two-line name plus the clipping warning) comes to about 458 pt against roughly 468 pt available. This is still an estimate. Nobody has checked it on screen.
- **Speed menu:** it now has a 58 pt minimum width.
- **"Track actions" label:** it uses `size.sectionTitle` again, so it matches the track name at both window sizes.
- **Doc comment:** it now says the fit hasn't been checked on screen.
- **VoiceOver heading:** keeping "Track actions" as a plain menu button rather than also marking it a heading is a sound call. The track name is still a heading and the menu has its own label.

Every Phase 7 "Must still work" control is still reachable:

- **Level:** Fit, including "Measuring…" and its disabled state, and the clipping warning under the slider.
- **Speed:** − and + in 1% steps, and the ½×, 1× and 2× presets in the percentage menu.
- **Direction:** the menu.
- **Trims:** both rows.
- **Track actions menu:** Join (its confirmation is attached to the row that stays put), Append with its targets, Detach for appended pieces, separate Move up and Move down, and the two resets after a divider, each with its own enabled state.
- **Locked tape:** `.disabled(edit.isOnSite)` still covers both `TrackSettings` and `TrackActions`.
- **No selection:** "Select a track" and the settings note.
- **Return:** stays pinned outside the scrolling part.

Nothing touches masters, pushes, the site clock, the live site or stored data. None of the SwiftUI traps from CLAUDE.md come back: there's no `.fixedSize(horizontal: false, vertical: true)`, and labels in narrow rows have `.fixedSize()`. The deployment target is macOS 26, so `.menuStyle(.button)` and `.menuIndicator` are available. There's no scope creep.

## Findings

1. **[minor] The fit at 900×692 is still only an estimate.** `Remanence/EditView.swift:851-879`. The roughly 10 pt margin is enough on paper, but someone should look at three cases on screen before committing: a two-line name with the clipping warning, a one-line name, and a locked tape.
2. **[minor] Return now sits right on the window footer with no gap.** `Remanence/EditView.swift:836-838`. The mock leaves room under the button for a bottom inset. Without one, the paper button may touch the footer rule. Check it in the same on-screen pass, and put back 2–3 pt if it touches.
3. **[minor] The 58 pt width doesn't cover speeds with a decimal.** `Remanence/EditView.swift:1023`. `percent` can show values like "100.5%" or "51.0%" (`:1074-1077`). Those, plus the menu arrow, may be wider than 58 pt, and then − shifts again. Whole percentages, the common case, are fine.
4. **[minor] Two checks only possible in the running app, carried over from the last review:**
   - Does the `.menuStyle(.button)` and `.buttonStyle(.plain)` row draw the serif label, and open from anywhere across the full width? `Remanence/EditView.swift:1128-1135`, `:1144-1166`
   - Does the Join confirmation appear after the menu closes?
5. **[minor] The heading now starts at the very top of the inspector, with no inset.** `Remanence/EditView.swift:856-858`, `:881-893`. Confirm on screen that the small "Track 02 / Side A" label still lines up with the top of the track list, as in mock 04.

VERDICT: PASS