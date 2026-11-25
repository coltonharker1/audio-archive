**Fixed**
- Past Read Along lines use plain `Theme.muted` (about 5.6:1 on paper). Upcoming lines stay darker, so past lines are still the faintest. `ReadAlongView.swift:271`
- While search is up, the sidebar highlights where clearing it returns: Catalog, Site Posts, Setup, or the shelf or collection. `AppModel.swift:235`
- Catalog staging already lives on `AppModel` and is only refreshed with `follow`. The new test keeps a drag and a typed number across two refreshes. `CatalogStagingTests.swift:148`
- `TapePanel.swift` is gone. `project.yml` takes the whole `Remanence/` folder, and the reported build succeeded.
- An empty shelf sets a blank footer instead of falling through to "All caught up". `LibraryView.swift:392`
- The hero collection name is a plain button that opens the collection, same as the shelf rows and the tape header. `ShelfView.swift:135`
- The last-opened row keeps the picked background only while no other visible row is selected. `ShelfView.swift:80`
- Review close-up bars fill the canvas that is already inset for the marker flags. `ReviewView.swift:333`
- A waveform click seeks, then selects that track so the close-up and inspector follow it. The double-click toggle is gone so that first click does not immediately close the close-up. Title click and Esc still close it. `EditView.swift:455`
- When playback continues into an appended piece, the selection moves with it through `expand`, which does not take focus out of a name field. `EditModel.swift:94`
- Sided rows no longer show the recording label. Appended pieces and unsided recordings still do. `EditView.swift:296`
- `TrackHandoff.time` keeps "Edit selected track" on the track the note names when the playhead has just crossed a marker. `TrackHandoff.swift:45`, `AppModel.swift:643`
- The hairline between the drag hint and "Return to Side A" is gone. `EditView.swift:823`

**Left as is**
- Catalog staging did not need a view change. Coming back only calls `follow`, which keeps staged numbers until Apply, Revert, or quit.
- Collection rows already match plan section 4.5 and mock 05: one click selects, and the title, a double-click, Return, or Open opens Review. `CollectionView.swift:458`

No hard-rule, SwiftUI-trap, or scope problems. The supplied check reports the build and 448 tests passed. These screens were not opened in the running app.

VERDICT: PASS
