/// The tabs above the shelf, each showing some of the library's tapes.
public enum ShelfFilter: CaseIterable, Identifiable, Sendable {
    case all, review, progress, site

    public var id: Self { self }

    public var label: String {
        switch self {
        case .all: "All reels"
        case .review: "Ready to review"
        case .progress: "In progress"
        case .site: "On the site"
        }
    }

    public func includes(_ tape: ShelfTape) -> Bool {
        switch self {
        case .all:
            return true
        case .review:
            return tape.tape.pushedAt == nil && tape.tape.approvedAt == nil && tape.status == .idle
        case .progress:
            if case .failed = tape.status { return true }
            return tape.status.isActive
        case .site:
            return tape.tape.pushedAt != nil
        }
    }
}
