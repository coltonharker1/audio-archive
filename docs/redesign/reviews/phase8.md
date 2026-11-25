1. **[minor]** `Remanence/ReviewModel.swift:47` — The row highlight and the “Edit selected track” note follow `player.currentTime`, which advances about four times a second and stays put on pause. `editSelectedTrack()` hands off `player.preciseTime` (`Remanence/AppModel.swift:631`). In the quarter-second after the playhead crosses a marker, the note can name the earlier track while Edit opens the later one. The highlight also treats a playhead up to 5 ms before a marker as already on the next track (`TrackHandoff.tolerance`).

2. **[minor]** `Remanence/EditView.swift:817` — Mock 04 places “Return to Side A” directly under the drag hint. The inspector draws a hairline between that hint and the button.

VERDICT: PASS
