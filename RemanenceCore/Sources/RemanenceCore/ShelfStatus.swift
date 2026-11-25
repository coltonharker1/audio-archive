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

/// Where a tape or a collection stands with the site, whatever else is happening to it.
public enum SitePresence: Equatable, Sendable {
    case localOnly
    case draftOnSite
    case published

    /// A tape being worked on, or one whose work failed, keeps its place on the site.
    /// One the site has in a form that can't be read counts as a draft.
    public init(_ tape: ShelfTape) {
        var settled = tape
        settled.status = .idle
        switch ShelfStatus(settled) {
        case .published: self = .published
        case .draftOnSite, .onSiteUnread: self = .draftOnSite
        case .recording, .working, .failed, .waiting, .approved, .readyToReview: self = .localOnly
        }
    }

    public init(_ collection: TapeCollection) {
        if !collection.isOnSite {
            self = .localOnly
        } else {
            self = collection.sitePublished ? .published : .draftOnSite
        }
    }

    public var label: String {
        switch self {
        case .localOnly: "Local only"
        case .draftOnSite: "Draft on site"
        case .published: "Published"
        }
    }
}

/// What the footer counts under a collection.
public struct CollectionCounts: Equatable, Sendable {
    public let reels: Int
    public let publishedReels: Int
    /// The collection's own page, which is published apart from its reels.
    public let collection: SitePresence

    public init(_ collection: TapeCollection, reels: [SitePresence]) {
        self.reels = reels.count
        publishedReels = reels.count { $0 == .published }
        self.collection = SitePresence(collection)
    }

    public var footerNote: String {
        let all = reels == 1 ? "1 reel" : "\(reels) reels"
        let published = publishedReels == 1 ? "1 published reel" : "\(publishedReels) published reels"
        let own = switch collection {
        case .localOnly: "Collection local only"
        case .draftOnSite: "Collection draft on site"
        case .published: "Collection published"
        }
        return [all, published, own].joined(separator: " · ")
    }
}
