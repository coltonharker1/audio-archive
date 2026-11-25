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
