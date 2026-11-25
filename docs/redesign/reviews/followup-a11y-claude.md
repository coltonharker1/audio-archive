Reviewer: Claude Opus (`claude -p --model opus`, a fresh read-only session separate from the implementer), in place of grok-4.7-build-fast because the Grok Build usage balance ran out (HTTP 402).

I've finished the diff and checked the context around the labels, so here's the review.

## Summary

Commit 9807478 only changes views: 103 added lines across 13 files. It adds `.accessibilityLabel` to buttons whose custom styles or composite labels (icon plus text, text plus count or key letter) gave them no usable title. It also splits the recording clock into the label "Recording time" with a live value.

I checked each label against its visible title. They match, including the ones that change with state: Apply, Review / Review Side X, Record Next Side / Record Side X, Publish / Unpublish, Hear the join / Playing…, Fit / Measuring…, Rewrite / Write a Summary, finding details, and Add N reels. Where the fixer turned a count into an `accessibilityValue`, the value matches the visible number:
- Shelf tabs use `model.shelf.filter(filter.includes).count`.
- Sidebar collections use `collection.tapeIDs.count`.
- Site Post track rows use the duration.

The track row label uses the same `typed.isEmpty ? unnamed : typed` as its visible text. The tape tabs' `tab.tabTitle ?? ""` matches the visible `Text(tab.tabTitle ?? "")`, and `Route.tapeTabs` are all tape tabs, which always have a title.

Hard rules and traps:
- **Hard rules:** no data, schema, site, push or master code is touched. No SwiftUI layout modifiers were added, so none of the `fixedSize` or measurement traps apply.
- **Mocks:** nothing visual changed, so the mocks still hold.
- **Scope:** going past the given list was within the brief ("every unlabeled button"). Every change follows the same pattern.

Nothing is blocking.

## Findings

1. **[minor]** `Remanence/LibraryView.swift:258` The dot's own `.accessibilityLabel("Recording now")` is still there, but the row's new label and value replace the button's children (`LibraryView.swift:344-345`), so it now does nothing. It's harmless. Removing it, or adding a comment, would stop someone later thinking the dot is what announces recording.

2. **[minor]** `Remanence/ReviewView.swift:731,734` The labels "−0.1 s" and "+0.1 s" copy the terse visible text, and VoiceOver will read them roughly as "minus zero point one s". Something like "Move marker earlier 0.1 seconds" and "Move marker later 0.1 seconds", or reusing the help text, would be clearer. This is not a regression, since before there was no usable title at all.

3. **[minor]** `Remanence/RecordView.swift:537` The Re-record confirmation button is a `confirmationDialog` button, which already has a system title. The fixer says so too. The added label does nothing and slightly widens the diff.

4. **[minor]** `Remanence/CollectionView.swift:1059-1060` In Add Reels, a tape with no catalog number shows "—", and the label just leaves the number out, which is fine. When a reel isn't in another collection, it gets `accessibilityHint("")`. An empty hint is harmless, but a conditional modifier, or leaving the hint off, would be cleaner. When the reel is in another collection, the hint repeats the visible "In X" line, which is acceptable.

5. **[minor]** (spread across the commit) Most labels repeat their string literal next to the visible title, for example `Button("Revert")` followed by `.accessibilityLabel("Revert")`. That's about 80 pairs that can drift apart when someone edits one copy. For the buttons with dynamic titles (`RecordView.swift:624-641`), the fixer already pulled the title into a `let`. A shared helper, or the same `let` pattern for the dynamic ones, would cut that risk. Nothing has drifted yet.

6. **[minor]** Process: nobody has checked this in the running app's accessibility tree. The fixer couldn't launch the app, and the Grok review didn't run (HTTP 402). Composite labels on `.plain` buttons and the custom `PaperButtonStyle` / `ActionLineStyle` buttons should pick these labels up, but a short Accessibility Inspector pass is still worth doing. Focus on the sidebar, the Shelf tabs, the Recording buttons and clock, and the Add Reels checkboxes. Launch with `open -g` and don't post system-wide input.

VERDICT: PASS