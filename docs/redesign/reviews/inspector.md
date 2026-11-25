Reviewer: Claude Opus (`claude -p --model opus`, a fresh read-only session separate from the implementer), in place of grok-4.7-build-fast because the Grok Build usage balance ran out (HTTP 402).

**Summary.** The staged change re-lays out the Edit inspector to follow `edit-inspector-space.md`. The value of Level now sits above the slider. Speed is now − / a percentage menu holding ½×, 1× and 2× / +. Rows are tighter, and Track actions became a full-row menu. Everything on the Phase 7 "Must still work" list is still reachable:

- **Fit and the clipping warning:** Fit still shows "Measuring…", and the warning still appears under Level.
- **Speed:** 1% steps and the ½×, 1×, 2× presets.
- **Track actions menu:** Join with its confirmation, Append, Detach for appended pieces, Move up and down, and both resets with separate enabled states.
- **Locked tape:** disabling still covers both `TrackSettings` and `TrackActions`.

The masters sentence, the locked text, the drag hint and the pinned Return button are kept. Nothing in the diff touches data, push, masters or the site. I found no CLAUDE.md SwiftUI trap: there's no `.fixedSize(vertical:)`, and labels in narrow rows use `.fixedSize()`. Keeping the `ScrollView` instead of a plain stack is a reasonable choice, since it lets smaller windows scroll.

The one problem is the required fit. Nobody has measured it, and by my estimate the worst case doesn't quite fit.

1. **[blocking] Nobody has shown that Track actions fits without scrolling at 900×692, and my estimate of the worst case slightly overflows.** `Remanence/EditView.swift:852-877`, `:820-838`
   - **Space available:** the old screenshot `~/.remanence-redesign/shots/after/11-edit-900.png` shows the inspector column is about 468 pt tall.
   - **Worst case:** a two-line name plus the clipping warning. Adding up the new code's paddings and the real control heights comes to about 469 pt:
     - heading about 78 pt
     - Level with the warning about 95 pt
     - Speed about 33 pt
     - Direction about 31 pt
     - the two trim rows 52 pt
     - the note, which wraps to 3 lines at this width as the screenshot shows, about 60 pt
     - Track actions about 34 pt
     - hint and Return about 86 pt
   - **Result:** that worst case is the one the design said must fit, and it sits right at the limit or slightly over. The design's budget was 462 + 8. When it overflows, the `ScrollView` scrolls quietly and cuts off the bottom of Track actions, and the scroller sits over the values, as in the old shot.
   - **Common case:** a one-line name with no warning fits with about 70 pt to spare.
   - **Fix:** take back about 10 pt (for example the heading's 6 pt top padding, or the 5 pt under Return, which already sits above the footer). Then check both cases on screen, plus a locked tape, before committing.
2. **[minor] The − button moves when the percentage changes width.** `Remanence/EditView.swift:1006-1023` The old percentage text had `.frame(minWidth: 46)`, and the new `Menu` has no fixed width. The row is pinned to the right by `Spacer`, so going from 100% to 99% moves "−" about a digit's width. Clicking − repeatedly can then miss or open the menu. Give the menu a minimum width.
3. **[minor] The Track actions label is a fixed 21 pt in wide windows too.** `Remanence/EditView.swift:1147` Before, it used `size.sectionTitle`, the same as the track name. In wide windows the name is now 27 pt and "Track actions" 21 pt. In mock 04 the two are the same `h3` style. Use `size.sectionTitle`, or pass the size through again.
4. **[minor] VoiceOver no longer treats "Track actions" as a heading.** `Remanence/EditView.swift:1128-1131` The implementer acknowledges this. The menu has a label and the selected track's name is still a heading, so it's a small step back, not a blocker.
5. **[minor] Things to check on screen, untested on this macOS:**
   - **Track actions row** (`Remanence/EditView.swift:1127-1129`): whether `.menuStyle(.button)` with `.buttonStyle(.plain)` really draws the custom serif label, and opens from anywhere across the full width set by `.frame(maxWidth: .infinity)`.
   - **Join confirmation:** whether it appears after the menu closes. The `.confirmationDialog` is on the `Menu` itself, which is the right place.
6. **[minor] Departure from the design:** keeping the `ScrollView` instead of the `VStack` with `Spacer` is explained and fine. However, the doc comment at `Remanence/EditView.swift:850` says "At the usual window size it all fits". Nobody has measured that, so either remove it or confirm it under finding 1.

VERDICT: FAIL