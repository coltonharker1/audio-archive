import Foundation
import Testing
@testable import RemanenceCore

@Suite struct ShelfFilterTests {
    private static func tape(_ status: TapeStatus = .idle, approved: Bool = false, pushed: Bool = false) -> ShelfTape {
        var tape = Tape(uuid: UUID().uuidString, title: "Station break", createdAt: Date())
        if approved { tape.approvedAt = Date() }
        if pushed { tape.pushedAt = Date() }
        return ShelfTape(tape: tape, items: [], status: status)
    }

    private static func filters(showing tape: ShelfTape) -> [ShelfFilter] {
        ShelfFilter.allCases.filter { $0.includes(tape) }
    }

    @Test func tabsKeepTheirOrderAndWording() {
        #expect(ShelfFilter.allCases == [.all, .review, .progress, .site])
        #expect(ShelfFilter.allCases.map(\.label) == ["All reels", "Ready to review", "In progress", "On the site"])
    }

    @Test func idleTapeIsReadyToReview() {
        #expect(Self.filters(showing: Self.tape()) == [.all, .review])
    }

    @Test(arguments: [TapeStatus.waiting, .working(type: .transcribe, jobID: 1)])
    func waitingAndWorkingTapesAreInProgress(status: TapeStatus) {
        #expect(Self.filters(showing: Self.tape(status)) == [.all, .progress])
    }

    @Test func failedTapeIsInProgress() {
        #expect(Self.filters(showing: Self.tape(.failed("No room left"))) == [.all, .progress])
    }

    @Test func approvedAndUnpushedTapeIsOnlyInAll() {
        #expect(Self.filters(showing: Self.tape(approved: true)) == [.all])
    }

    @Test func pushedTapeIsOnTheSite() {
        #expect(Self.filters(showing: Self.tape(pushed: true)) == [.all, .site])
        #expect(Self.filters(showing: Self.tape(approved: true, pushed: true)) == [.all, .site])
    }

    @Test(arguments: [TapeStatus.waiting, .working(type: .peaks, jobID: 2), .failed("Stopped")])
    func processingCountsWhateverElseIsTrue(status: TapeStatus) {
        #expect(Self.filters(showing: Self.tape(status, approved: true)) == [.all, .progress])
        #expect(Self.filters(showing: Self.tape(status, pushed: true)) == [.all, .progress, .site])
    }
}
