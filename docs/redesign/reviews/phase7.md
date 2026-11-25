1. **[minor]** Clicking a row's waveform loads that track and moves the playhead, but only the title selects it. The close-up and the inspector can stay on another track while you hear this one, so a level change is applied to the selected track. `Remanence/EditView.swift:448`

2. **[minor]** After playback continues into an appended piece, the play button stays on pause, but the close-up clock and playhead only follow the selected lane. The clock reads `Track 0:00` and the close-up playhead disappears. `Remanence/EditView.swift:535`

3. **[minor]** A sided row draws the recording label (`A1`) beside the site number. The mock and the phase's row are the drag handle, the site number, the serif name, and `Side A / 0:36`. `Remanence/EditView.swift:294`

VERDICT: PASS
