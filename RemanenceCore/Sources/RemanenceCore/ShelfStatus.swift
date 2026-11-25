/// Where a tape stands, as the shelf says it. Whatever is happening to the tape now
/// comes before where it stands with the site.
public enum ShelfStatus: Equatable, Sendable {
    case recording
    case working(JobType)
    case failed(String)
    case waiting
    case published
    case draftOnSite
    /// On the site, but what the site had can't be read, so whether it's public isn't
    /// known. It reads as a draft, as it does in the Catalog.
    case onSiteUnread
    case approved
    case readyToReview

    public init(_ tape: ShelfTape, isRecording: Bool = false) {
        if isRecording {
            self = .recording
            return
        }
        switch tape.status {
        case .working(let type, _):
            self = .working(type)
        case .failed(let reason):
            self = .failed(reason)
        case .waiting:
            self = .waiting
        case .idle:
            if tape.tape.pushedAt == nil {
                self = tape.tape.approvedAt == nil ? .readyToReview : .approved
            } else if let snapshot = SiteSnapshot.decode(tape.tape.siteSnapshot) {
                self = snapshot.published ? .published : .draftOnSite
            } else {
                self = .onSiteUnread
            }
        }
    }

    /// The words for a settled tape. Nil while something is happening or has gone
    /// wrong, which the app words itself, with any progress.
    public var label: String? {
        switch self {
        case .published: "Published"
        case .draftOnSite, .onSiteUnread: "Draft on site"
        case .approved: "Approved for push"
        case .readyToReview: "Ready to review"
        case .recording, .working, .failed, .waiting: nil
        }
    }
}
