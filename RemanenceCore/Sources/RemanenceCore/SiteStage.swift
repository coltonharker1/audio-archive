/// What Site Post knows about a tape and the site.
public struct SiteFacts: Equatable, Sendable {
    public var isOnSite: Bool
    /// Whether the post is public, as the site last had it. Nil when the app hasn't
    /// read what the site has.
    public var sitePublished: Bool?
    public var isApproved: Bool
    public var hasKey: Bool
    /// Something written here that an update would send.
    public var hasChanges: Bool
    /// Why nothing can be sent right now. Empty when there's no reason to put beside
    /// the button, and nil when nothing is in the way.
    public var blockedReason: String?
    /// This tape's first push is running.
    public var isPushing: Bool
    public var pushFailed: Bool

    public init(isOnSite: Bool = false, sitePublished: Bool? = nil, isApproved: Bool = false, hasKey: Bool = true,
                hasChanges: Bool = false, blockedReason: String? = nil, isPushing: Bool = false, pushFailed: Bool = false) {
        self.isOnSite = isOnSite
        self.sitePublished = sitePublished
        self.isApproved = isApproved
        self.hasKey = hasKey
        self.hasChanges = hasChanges
        self.blockedReason = blockedReason
        self.isPushing = isPushing
        self.pushFailed = pushFailed
    }

    /// A post on the site that the app hasn't read can't be edited, or a later update
    /// would be worked out against nothing.
    public var needsRefresh: Bool { isOnSite && sitePublished == nil }
}

/// A step Site Post can offer.
public enum SiteAction: Equatable, Sendable {
    case approve, createDraft, tryAgain, stop, refresh, publish, unpublish, update

    public var title: String {
        switch self {
        case .approve: "Approve for push"
        case .createDraft: "Create unpublished draft"
        case .tryAgain: "Try Again"
        case .stop: "Stop"
        case .refresh: "Refresh from site…"
        case .publish: "Publish reel"
        case .unpublish: "Unpublish reel"
        case .update: "Update on site"
        }
    }
}

/// Where a tape's post stands, and so what Site Post says and offers. This only
/// decides what's shown. It sends nothing.
public enum SiteStage: Equatable, CaseIterable, Sendable {
    case needsApproval
    case needsKey
    case readyToCreateDraft
    case pushing
    case needsRefresh
    case draft
    case draftWithChanges
    case published
    case publishedWithChanges

    public init(_ facts: SiteFacts) {
        if facts.isPushing {
            self = .pushing
        } else if !facts.isOnSite {
            self = !facts.isApproved ? .needsApproval : facts.hasKey ? .readyToCreateDraft : .needsKey
        } else if !facts.hasKey {
            self = .needsKey
        } else if let published = facts.sitePublished {
            if published {
                self = facts.hasChanges ? .publishedWithChanges : .published
            } else {
                self = facts.hasChanges ? .draftWithChanges : .draft
            }
        } else {
            self = .needsRefresh
        }
    }
}

/// The words and buttons for one set of facts.
public struct SiteStatus: Equatable, Sendable {
    public let facts: SiteFacts
    public let stage: SiteStage

    public init(_ facts: SiteFacts) {
        self.facts = facts
        stage = SiteStage(facts)
    }

    /// A post on the site that can't be read counts as a draft, as on the shelf.
    public var heading: String {
        guard facts.isOnSite else { return "Local only" }
        return facts.sitePublished == true ? "Published" : "Draft on site"
    }

    /// Who can see the post, and what comes next.
    public var explanation: String {
        switch stage {
        case .needsApproval:
            return "Nothing from this tape is on the site. Approve it when it’s ready to push."
        case .needsKey:
            guard facts.isOnSite else { return "Approved for push. The site’s key is needed to create the draft." }
            guard let published = facts.sitePublished else {
                return "It can’t be edited until it’s refreshed from the site, which needs the site’s key."
            }
            return "\(published ? "Visitors can see it." : "Only you can see it.") The site’s key is needed to change it."
        case .readyToCreateDraft:
            return "Approved for push. The audio, post text and photos go to the site as an unpublished draft, with a catalog number from the site."
        case .pushing:
            return "Sending this tape to the site as an unpublished draft."
        case .needsRefresh:
            return "Refresh from the site to load what it has now, including anything changed in its admin. Then edit here and send the changes with Update on site."
        case .draft:
            return "Only you can see it. Publish it to make this reel visible to visitors."
        case .draftWithChanges:
            return "Only you can see it. Update the site to send what’s changed here."
        case .published:
            return "Visitors can see it and listen on the site."
        case .publishedWithChanges:
            return "Visitors can see it. They get what’s changed here once you update the site."
        }
    }

    /// The stage's one main button. There's none while the key is missing.
    public var mainAction: SiteAction? {
        switch stage {
        case .needsApproval: .approve
        case .needsKey: nil
        case .readyToCreateDraft: facts.pushFailed ? .tryAgain : .createDraft
        case .pushing: .stop
        case .needsRefresh: .refresh
        case .draft: .publish
        case .published: .unpublish
        case .draftWithChanges, .publishedWithChanges: .update
        }
    }

    /// With changes to send, publishing or unpublishing sits beside Update.
    public var besideAction: SiteAction? {
        switch stage {
        case .draftWithChanges: .publish
        case .publishedWithChanges: .unpublish
        default: nil
        }
    }

    /// The quieter actions under the buttons.
    public var otherActions: [SiteAction] {
        switch stage {
        case .draft, .published: [.update, .refresh]
        case .draftWithChanges, .publishedWithChanges: [.refresh]
        default: []
        }
    }

    public func isEnabled(_ action: SiteAction) -> Bool {
        switch action {
        // Neither sends anything.
        case .approve, .stop: true
        case .update: facts.hasChanges && facts.blockedReason == nil
        case .publish, .unpublish: !facts.needsRefresh && facts.blockedReason == nil
        case .createDraft, .tryAgain, .refresh: facts.blockedReason == nil
        }
    }

    /// Removing a post is offered on any tape that's on the site, with a key.
    public var offersRemoval: Bool { facts.isOnSite && facts.hasKey && stage != .pushing }

    public var canRemove: Bool { offersRemoval && !facts.needsRefresh && facts.blockedReason == nil }

    /// Approval can be taken back only while the tape isn't on the site.
    public var canWithdrawApproval: Bool { !facts.isOnSite && facts.isApproved && !facts.isPushing }
}
