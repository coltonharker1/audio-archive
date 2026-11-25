# Performance results: phases 1 and 2

Measured 2026-11-25 on the MacBook Pro (M1 Pro, macOS 27.2) with a Debug build (derivedDataPath `.build/xcode-perf`), using a renamed scratch copy of the app (`RemanenceScratch`), a scratch library (`-libraryPath $TMPDIR/remanence-scratch`, `-siteURL http://127.0.0.1:9`), and a 10-minute stereo 48 kHz tape plus two 2:30 tapes. Driven by Accessibility actions and per-pid key and scroll events; `sample` at 1 ms. Script: `~/.remanence-redesign/perf/measure.sh`. "Responsive" is the time until the window answers an Accessibility query again; AX -25204 means the main thread could not answer.

| Action (10-minute tape) | Before (7490cd2) | After phase 1 (a9ca9b1) | After phase 2 (0597c83) |
|---|---|---|---|
| Edit -> Review | 75.6 s press, AX -25204 (frozen ~74 s) | 0.59 s | 0.58 s |
| Read Along -> Review | 67.0 s, AX -25204 | 0.56 s | 0.51 s |
| Site Post -> Review | 15.0 s, AX -25204 | 0.71 s | 0.78 s |
| Main-thread samples in `Waveform.levels` / `drawLevels` across those three returns | 41,902 / 12,562 | 24 / 1 | 1 / 0 |
| Zoom: 12 `=`/`-` keys over 7 s, samples in levels / drawLevels | 21 / 3 | 18 / 1 | 0 / 2 |
| Pan: 120 horizontal scroll events, samples in levels / drawLevels | 122 / 9 | 120 / 12 | 7 / 7 |
| Playback 8 s, samples in levels / drawLevels | 2 / 0 | 0 / 0 | 0 / 0 |

Opening the tape (0.3-0.4 s), Edit, Read Along and Site Post (0.2-1.0 s) were unchanged and include the polling overhead of the measurement.

Cause, confirmed with temporary gated logging before the fix (removed in a9ca9b1): on a return visit `ReviewModel.observe` cleared the review while `OverviewStrip` was still mounted; its body ran once with the 0.001 s fallback duration, so the zoom rectangle was 34,920,000 pt wide, the ZStack and canvas grew to it, and the canvas drew 17,460,000 columns on the main thread. Edit never drew its zoom rectangle in that state (it is only drawn when zoomSpan < spanLength), so it was not exposed.

## Phases 3 and 4: not done

After phase 2 the remaining waveform work on the main thread during zoom, pan and playback is under 15 samples (about 15 ms in total) per burst, and no single press stalls. Phase 3 (equatable canvases) would save at most a few milliseconds, and Phase 4 (keeping decoded waveforms between tabs) only removes a brief "Reading the waveform…" state; the decode already runs off the main thread and returns to Review are about 0.5 s including measurement overhead. Neither is worth the added complexity now. Phases 5 and 6 were not approved.
