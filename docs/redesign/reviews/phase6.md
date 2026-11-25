1. **[blocking]** The left heading and the track-column cap use the opening track's name, so they change when that track is renamed and no longer read "Side A". `selectedItem.name` is the track with no start marker (`Library.fetchShelf`), while the header subtitle and the row detail already use `source.side`. The mock keeps "Side A" as the section title and the cap, and puts "Let it ring" on the row. Fall back to the recording name only when the side is nil. `Remanence/ReviewView.swift:67` and `Remanence/ReviewView.swift:720`.

2. **[minor]** Zoom, Hear the join, nudge, Delete, trim, Reset, and Undo never call `endTyping()`, unlike play, Add marker, and scrub. Those controls use a custom button style, not `NSButton`, so a name field can stay first responder and the next M or Space is typed into the name. `Remanence/ReviewView.swift:117`, `Remanence/ReviewView.swift:633`, `Remanence/ReviewView.swift:675`.

3. **[minor]** The footer hints are the right three lines, but the separators are double-spaced (`"  ·  "`) rather than the plan's `"Space Play / pause · J K L Shuttle · M Add marker"`. `Remanence/AppModel.swift:106`.

VERDICT: CHANGES
