/// Where a tape was opened from, and so where Back leads from any of its screens.
public enum TapeOrigin: Equatable, Sendable {
    case shelf
    case collection(Int64)
    /// Search results. `over` is the collection that was chosen underneath them, if any.
    case results(over: Int64?)

    /// The origin after going to one of a tape's screens. Moving between those screens
    /// keeps it. Arriving from anywhere else replaces it with the place just left.
    public func entering(fromTapeScreen: Bool, fromSearch: Bool, collectionID: Int64?) -> TapeOrigin {
        if fromTapeScreen { return self }
        if fromSearch { return .results(over: collectionID) }
        return collectionID.map(TapeOrigin.collection) ?? .shelf
    }

    /// Where Back goes now: the results only while there's still a search to show,
    /// otherwise the collection if it still exists, otherwise the shelf.
    public func back(searchText: String, collections: Set<Int64>) -> TapeOrigin {
        let collectionID: Int64?
        switch self {
        case .shelf:
            return .shelf
        case .collection(let id):
            collectionID = id
        case .results(let over):
            if !searchText.allSatisfy(\.isWhitespace) { return self }
            collectionID = over
        }
        guard let collectionID, collections.contains(collectionID) else { return .shelf }
        return .collection(collectionID)
    }
}
