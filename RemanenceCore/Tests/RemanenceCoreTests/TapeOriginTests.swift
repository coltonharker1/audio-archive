import RemanenceCore
import Testing

@Suite struct TapeOriginTests {
    /// Goes to a tape from a screen that isn't one of the tape's own.
    private func opened(fromSearch: Bool = false, collectionID: Int64? = nil) -> TapeOrigin {
        TapeOrigin.shelf.entering(fromTapeScreen: false, fromSearch: fromSearch, collectionID: collectionID)
    }

    @Test func openedFromTheShelf() {
        let origin = opened()
        #expect(origin == .shelf)
        #expect(origin.back(searchText: "", collections: [7]) == .shelf)
    }

    @Test func openedFromACollection() {
        let origin = opened(collectionID: 7)
        #expect(origin == .collection(7))
        #expect(origin.back(searchText: "", collections: [3, 7]) == .collection(7))
    }

    @Test func openedFromSearchResults() {
        let origin = opened(fromSearch: true)
        #expect(origin == .results(over: nil))
        #expect(origin.back(searchText: "weather", collections: []) == origin)
    }

    @Test(arguments: [
        TapeOrigin.shelf, .collection(7), .results(over: nil), .results(over: 7),
    ])
    func switchingThroughTheTabsKeepsTheOrigin(start: TapeOrigin) {
        var origin = start
        // Four tabs. Neither the search nor the chosen collection changes it.
        for collectionID: Int64? in [nil, 3, nil, 7] {
            origin = origin.entering(fromTapeScreen: true, fromSearch: false, collectionID: collectionID)
        }
        #expect(origin == start)
    }

    @Test func arrivingAgainReplacesTheOrigin() {
        let first = opened(fromSearch: true)
        let second = first.entering(fromTapeScreen: false, fromSearch: false, collectionID: nil)
        #expect(second == .shelf)
    }

    @Test(arguments: ["", "   "])
    func aSearchResultGoesToTheShelfOnceTheSearchIsCleared(searchText: String) {
        #expect(opened(fromSearch: true).back(searchText: searchText, collections: []) == .shelf)
    }

    @Test func aSearchOverACollectionReturnsToItOnceCleared() {
        let origin = opened(fromSearch: true, collectionID: 7)
        #expect(origin.back(searchText: "weather", collections: [7]) == origin)
        #expect(origin.back(searchText: "", collections: [7]) == .collection(7))
    }

    @Test func aDeletedCollectionFallsBackToTheShelf() {
        #expect(opened(collectionID: 7).back(searchText: "", collections: [3]) == .shelf)
        #expect(opened(fromSearch: true, collectionID: 7).back(searchText: "", collections: []) == .shelf)
    }
}
