import Foundation
import GRDB
import Testing
@testable import RemanenceCore

@Suite struct ShelfStatusTests {
    private static func tape(
        _ status: TapeStatus = .idle,
        approved: Bool = false,
        pushed: Bool = false,
        snapshot: String? = nil
    ) -> ShelfTape {
        var tape = Tape(uuid: UUID().uuidString, title: "Station break", createdAt: Date())
        if approved { tape.approvedAt = Date() }
        if pushed { tape.pushedAt = Date() }
        tape.siteSnapshot = snapshot
        return ShelfTape(tape: tape, items: [], status: status)
    }

    private static func snapshot(published: Bool) -> String {
        SiteSnapshot(
            published: published,
            fields: .init(title: "Station break", medium: "cassette"),
            tracks: [],
            images: []
        ).encoded
    }

    @Test func recordingTape() {
        let status = ShelfStatus(Self.tape(), isRecording: true)
        #expect(status == .recording)
        #expect(status.label == nil)
    }

    @Test(arguments: [JobType.prep, .transcribe, .summarize, .peaks])
    func workingTapeKeepsItsJobType(type: JobType) {
        let status = ShelfStatus(Self.tape(.working(type: type, jobID: 7)))
        #expect(status == .working(type))
        #expect(status.label == nil)
    }

    @Test func failedTapeKeepsItsReason() {
        let status = ShelfStatus(Self.tape(.failed("No room left")))
        #expect(status == .failed("No room left"))
        #expect(status.label == nil)
    }

    @Test func waitingTape() {
        let status = ShelfStatus(Self.tape(.waiting))
        #expect(status == .waiting)
        #expect(status.label == nil)
    }

    @Test func publishedTape() {
        let status = ShelfStatus(Self.tape(pushed: true, snapshot: Self.snapshot(published: true)))
        #expect(status == .published)
        #expect(status.label == "Published")
    }

    @Test func draftOnSiteTape() {
        let status = ShelfStatus(Self.tape(pushed: true, snapshot: Self.snapshot(published: false)))
        #expect(status == .draftOnSite)
        #expect(status.label == "Draft on site")
    }

    @Test(arguments: [nil, "", "not JSON", #"{"published":true}"#])
    func pushedTapeWithoutAReadableSnapshotReadsAsADraft(snapshot: String?) {
        let status = ShelfStatus(Self.tape(pushed: true, snapshot: snapshot))
        #expect(status == .onSiteUnread)
        #expect(status.label == "Draft on site")
    }

    @Test func approvedAndUnpushedTape() {
        let status = ShelfStatus(Self.tape(approved: true))
        #expect(status == .approved)
        #expect(status.label == "Approved for push")
    }

    @Test func untouchedTapeIsReadyToReview() {
        let status = ShelfStatus(Self.tape())
        #expect(status == .readyToReview)
        #expect(status.label == "Ready to review")
    }

    /// A snapshot only counts once the tape has been pushed.
    @Test func unpushedTapeIsNeverPublished() {
        let status = ShelfStatus(Self.tape(snapshot: Self.snapshot(published: true)))
        #expect(status == .readyToReview)
    }

    @Test func siteStateComesBeforeApproval() {
        let tape = Self.tape(approved: true, pushed: true, snapshot: Self.snapshot(published: false))
        #expect(ShelfStatus(tape) == .draftOnSite)
    }

    @Test(arguments: [TapeStatus.idle, .waiting, .working(type: .transcribe, jobID: 1), .failed("Stopped")])
    func recordingComesBeforeEverything(status: TapeStatus) {
        let tape = Self.tape(status, approved: true, pushed: true, snapshot: Self.snapshot(published: true))
        #expect(ShelfStatus(tape, isRecording: true) == .recording)
    }

    @Test(arguments: [
        (TapeStatus.working(type: .peaks, jobID: 2), ShelfStatus.working(.peaks)),
        (.failed("Stopped"), .failed("Stopped")),
        (.waiting, .waiting),
    ])
    func processingComesBeforeSiteState(status: TapeStatus, expected: ShelfStatus) {
        let pushed = Self.tape(status, pushed: true, snapshot: Self.snapshot(published: true))
        #expect(ShelfStatus(pushed) == expected)
        #expect(ShelfStatus(Self.tape(status, approved: true)) == expected)
    }

    // MARK: A collection's footer

    private static func collection(onSite: Bool = false, published: Bool = false) -> TapeCollection {
        var collection = TapeCollection(uuid: UUID().uuidString, name: "The Cable Man", slug: "the-cable-man", createdAt: Date())
        if onSite { collection.siteUpdatedAt = "2026-11-24T12:00:00.000Z" }
        collection.sitePublished = published
        return collection
    }

    @Test(arguments: [
        (false, false, SitePresence.localOnly),
        (true, false, .draftOnSite),
        (true, true, .published),
    ])
    func reelsPlaceOnTheSite(pushed: Bool, published: Bool, expected: SitePresence) {
        let tape = Self.tape(pushed: pushed, snapshot: Self.snapshot(published: published))
        #expect(SitePresence(tape) == expected)
    }

    @Test func pushedReelWithoutAReadableSnapshotCountsAsADraft() {
        #expect(SitePresence(Self.tape(pushed: true, snapshot: "not JSON")) == .draftOnSite)
    }

    @Test(arguments: [TapeStatus.waiting, .working(type: .peaks, jobID: 3), .failed("Stopped")])
    func processingDoesNotMoveAReelOffTheSite(status: TapeStatus) {
        let published = Self.tape(status, pushed: true, snapshot: Self.snapshot(published: true))
        #expect(SitePresence(published) == .published)
        #expect(SitePresence(Self.tape(status, approved: true)) == .localOnly)
    }

    @Test func countsWithNoReelsPublished() {
        let counts = CollectionCounts(Self.collection(), reels: [.localOnly, .draftOnSite, .localOnly])
        #expect(counts.reels == 3)
        #expect(counts.publishedReels == 0)
        #expect(counts.footerNote == "3 reels · 0 published reels · Collection local only")
    }

    @Test func countsWithSomeReelsPublished() {
        let reels: [SitePresence] = [.localOnly, .published, .published, .localOnly, .draftOnSite, .localOnly]
        let counts = CollectionCounts(Self.collection(onSite: true), reels: reels)
        #expect(counts.reels == 6)
        #expect(counts.publishedReels == 2)
        #expect(counts.footerNote == "6 reels · 2 published reels · Collection draft on site")
    }

    @Test func countsOfOneAndNone() {
        #expect(CollectionCounts(Self.collection(), reels: [.published]).footerNote
                == "1 reel · 1 published reel · Collection local only")
        #expect(CollectionCounts(Self.collection(), reels: []).footerNote
                == "0 reels · 0 published reels · Collection local only")
    }

    /// The collection's own state doesn't follow its reels'.
    @Test(arguments: [
        (false, false, SitePresence.localOnly, "Collection local only"),
        (true, false, .draftOnSite, "Collection draft on site"),
        (true, true, .published, "Collection published"),
    ])
    func collectionsOwnState(onSite: Bool, published: Bool, expected: SitePresence, words: String) {
        let counts = CollectionCounts(Self.collection(onSite: onSite, published: published), reels: [.published])
        #expect(counts.collection == expected)
        #expect(counts.footerNote == "1 reel · 1 published reel · \(words)")
    }

    /// Work wins over a failure elsewhere on the same tape, which the library settles
    /// before the shelf sees it.
    @Test func workingComesBeforeFailed() async throws {
        let database = try AppDatabase(writer: DatabaseQueue())
        let shelf = try await database.writer.write { db in
            var tape = Tape(uuid: UUID().uuidString, title: "Station break", createdAt: Date())
            try tape.insert(db)
            var source = Source(tapeId: tape.id!, position: 0, masterPath: "masters/a.wav", duration: 60)
            try source.insert(db)
            var failed = Job.make(.prep, sourceID: source.id, now: Date())
            failed.status = .failed
            failed.error = "Stopped"
            try failed.insert(db)
            var running = Job.make(.peaks, sourceID: source.id, now: Date())
            running.status = .running
            try running.insert(db)
            return try Library.fetchShelf(db)
        }
        #expect(shelf.map { ShelfStatus($0) } == [.working(.peaks)])
    }
}
