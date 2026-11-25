Reviewer: grok-4.7-build-fast.



The log shows the bad frame with both review and waveform nil. I'll trace how `OverviewStrip` is built and whether the new duration fallback still covers that frame.

Phase 1 closes the confirmed Review hang. The bad frame in the log is a still-mounted `OverviewStrip` with no review, a 388 pt strip, duration treated as 0.001 s, and a zoom box 34,920,000 pt wide, which stretched the canvas to 17,460,000 columns. On that frame the strip now takes the captured waveform’s length (600 s in the log), so the box is 58.2 pt and the column count is 194, the same as the healthy frames. If both lengths are 0 it draws nothing. The box cannot be wider than the strip, columns cannot exceed 4,096, and `levels` enforces that cap. Normal tapes keep the old box width and column count. Edit’s zoom box is unchanged, which matches plan-review finding 2. Both Edit canvases use the shared column function. Diagnostic logging is gone. No forbidden files, no new races, and the SwiftUI traps are untouched. The Core tests lock the log’s numbers, the cap, and recorded ordinary levels. The scratch Accessibility, `sample`, and screenshot pass was not re-run.

1. [minor] `docs/redesign/reviews/grok-visual-97354f9.md:1` — This staged file is a visual review of commit 97354f9 (shelf title, Edit footer, Record toolbar). It is outside Phase 1.

VERDICT: PASS
