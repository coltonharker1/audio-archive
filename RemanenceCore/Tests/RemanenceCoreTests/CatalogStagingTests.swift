import Foundation
import Testing
@testable import RemanenceCore

@Suite struct CatalogStagingTests {
    private func tape(_ id: Int64, _ number: String?) -> ShelfTape {
        var tape = Tape(uuid: "tape-\(id)", catalogNumber: number, title: "Reel \(id)", createdAt: Date())
        tape.id = id
        return ShelfTape(tape: tape, items: [])
    }

    /// Reels 1 to 5, numbered RA-011 to RA-015.
    private var shelf: [ShelfTape] {
        (1...5).map { tape(Int64($0), "RA-0\($0 + 10)") }
    }

    private func staging(_ shelf: [ShelfTape]) -> CatalogStaging {
        var staging = CatalogStaging()
        staging.reset(shelf)
        return staging
    }

    private func proposed(_ staging: CatalogStaging, _ shelf: [ShelfTape]) -> [Int64: String] {
        Dictionary(uniqueKeysWithValues: staging.changes(in: shelf).map { ($0.tapeID, $0.catalogNumber) })
    }

    @Test func theListStartsByNumberWithTheUnnumberedApart() {
        let shelf = [tape(1, "RA-1000"), tape(2, nil), tape(3, "RA-002")]
        let staging = staging(shelf)
        #expect(staging.order == [3, 1])
        #expect(staging.unnumbered(in: shelf).map(\.id) == [2])
        #expect(staging.changes(in: shelf).isEmpty)
    }

    @Test func draggingAReelDownThreePlacesShiftsTheOnesBetween() {
        var staging = staging(shelf)
        staging.move(from: [0], to: 4, in: shelf)
        #expect(staging.order == [2, 3, 4, 1, 5])
        #expect(proposed(staging, shelf) == [2: "RA-011", 3: "RA-012", 4: "RA-013", 1: "RA-014"])
        #expect(Set(shelf.compactMap { staging.number(of: $0) }) == Set(shelf.compactMap(\.tape.catalogNumber)))
    }

    @Test func draggingUpAndBackLeavesNothingStaged() {
        var staging = staging(shelf)
        staging.move(from: [3], to: 1, in: shelf)
        #expect(staging.order == [1, 4, 2, 3, 5])
        #expect(proposed(staging, shelf) == [4: "RA-012", 2: "RA-013", 3: "RA-014"])
        staging.move(from: [1], to: 4, in: shelf)
        #expect(staging.order == [1, 2, 3, 4, 5])
        #expect(staging.staged.isEmpty)
    }

    @Test func typingAFreeNumberChangesThatReelAndSortsTheList() {
        var staging = staging(shelf)
        #expect(staging.commitTyping("20", for: 2, in: shelf) == .staged)
        #expect(staging.changes(in: shelf) == [Renumbering(tapeID: 2, catalogNumber: "RA-020")])
        #expect(staging.order == [1, 3, 4, 5, 2])
    }

    @Test func typingATakenNumberNeverMovesTheOtherReel() {
        var staging = staging(shelf)
        #expect(staging.commitTyping("RA-014", for: 2, in: shelf) == .staged)
        #expect(staging.changes(in: shelf) == [Renumbering(tapeID: 2, catalogNumber: "RA-014")])
        #expect(staging.staged[4] == nil)
        #expect(staging.number(of: shelf[3]) == "RA-014")
    }

    @Test func nonsenseChangesNothingAndSaysSo() {
        var staging = staging(shelf)
        let before = staging
        #expect(staging.commitTyping("twelve", for: 2, in: shelf)
            == .refused("“twelve” isn’t a catalog number. They look like RA-012."))
        #expect(staging == before)
    }

    @Test func blankPutsAStagedReelsNumberBack() {
        var staging = staging(shelf)
        _ = staging.commitTyping("20", for: 2, in: shelf)
        #expect(staging.commitTyping("  ", for: 2, in: shelf) == .restored)
        #expect(staging.number(of: shelf[1]) == "RA-012")
        #expect(staging.changes(in: shelf).isEmpty)
    }

    @Test func blankWhileAnotherChangeWaitsSortsTheReelBack() {
        var staging = staging(shelf)
        _ = staging.commitTyping("20", for: 2, in: shelf)
        _ = staging.commitTyping("30", for: 4, in: shelf)
        _ = staging.commitTyping("", for: 2, in: shelf)
        #expect(staging.order == [1, 2, 3, 5, 4])
        // A drag afterward deals the numbers by RA order, so reel 2 keeps its own.
        staging.move(from: [4], to: 4, in: shelf)
        #expect(proposed(staging, shelf) == [4: "RA-030"])
    }

    @Test func aDragHeldByTapeSurvivesTheListChangingUnderIt() {
        let shelf = shelf + [tape(6, nil)]
        var staging = staging(shelf)
        _ = staging.commitTyping("RA-016", for: 6, in: shelf)
        // Reel 6 is dragged to the top, but blanking its number first takes it out.
        _ = staging.commitTyping("", for: 6, in: shelf)
        staging.move([6], before: 1, in: shelf)
        #expect(staging.order == [1, 2, 3, 4, 5])
        #expect(staging.staged.isEmpty)

        // Reel 5 is dragged above reel 1 while a typed number re-sorts the list.
        _ = staging.commitTyping("RA-010", for: 3, in: shelf)
        staging.move([5], before: 1, in: shelf)
        #expect(staging.order == [3, 5, 1, 2, 4])
    }

    @Test func aDragByPlaceOutsideTheListDoesNothing() {
        var staging = staging(shelf)
        let before = staging
        staging.move(from: [7], to: 9, in: shelf)
        #expect(staging == before)
        staging.move(from: [0], to: 9, in: shelf)
        #expect(staging.order == [2, 3, 4, 5, 1])
    }

    @Test func blankOnAnUnstagedReelDoesNothing() {
        let shelf = shelf + [tape(6, nil)]
        var staging = staging(shelf)
        let before = staging
        #expect(staging.commitTyping("", for: 2, in: shelf) == .restored)
        #expect(staging.commitTyping("", for: 6, in: shelf) == .restored)
        #expect(staging == before)
    }

    @Test func typingAReelsOwnNumberDropsItsChange() {
        var staging = staging(shelf)
        _ = staging.commitTyping("20", for: 2, in: shelf)
        _ = staging.commitTyping("ra-12", for: 2, in: shelf)
        #expect(staging.staged.isEmpty)
        #expect(staging.order == [1, 2, 3, 4, 5])
    }

    @Test func revertingForgetsEverythingAndFollowsTheShelf() {
        var staging = staging(shelf)
        staging.move(from: [0], to: 4, in: shelf)
        let later = Array(shelf.dropLast())
        staging.reset(later)
        #expect(staging.staged.isEmpty)
        #expect(staging.order == [1, 2, 3, 4])
    }

    @Test func withNothingStagedTheListFollowsTheShelf() {
        var staging = staging(shelf)
        let later = [tape(6, "RA-001")] + shelf.dropFirst()
        staging.follow(later)
        #expect(staging.order == [6, 2, 3, 4, 5])
    }

    @Test func anUnnumberedTapeGivenANumberJoinsTheList() {
        let shelf = shelf + [tape(6, nil)]
        var staging = staging(shelf)
        #expect(staging.commitTyping("16", for: 6, in: shelf) == .staged)
        #expect(staging.changes(in: shelf) == [Renumbering(tapeID: 6, catalogNumber: "RA-016")])
        #expect(staging.order == [1, 2, 3, 4, 5, 6])
        #expect(staging.unnumbered(in: shelf).isEmpty)

        // Blanked again, it has no number and leaves the list.
        _ = staging.commitTyping("", for: 6, in: shelf)
        #expect(staging.staged.isEmpty)
        #expect(staging.order == [1, 2, 3, 4, 5])
        #expect(staging.unnumbered(in: shelf).map(\.id) == [6])
    }

    @Test func aTapeDeletedWhileStagedIsForgotten() {
        var staging = staging(shelf)
        _ = staging.commitTyping("20", for: 2, in: shelf)
        _ = staging.commitTyping("30", for: 4, in: shelf)
        let later = shelf.filter { $0.id != 2 }
        staging.follow(later)
        #expect(!staging.order.contains(2))
        #expect(staging.staged == [4: "RA-030"])

        // A drag afterward deals numbers only to tapes that exist.
        staging.move(from: [0], to: 2, in: later)
        #expect(staging.order == [3, 1, 5, 4])
        #expect(proposed(staging, later) == [3: "RA-011", 1: "RA-013", 4: "RA-030"])
    }

    @Test func aTapeAddedWhileStagedTakesItsPlace() {
        var staging = staging(shelf)
        _ = staging.commitTyping("20", for: 2, in: shelf)
        let later = shelf + [tape(6, "RA-016"), tape(7, nil)]
        staging.follow(later)
        #expect(staging.order == [1, 3, 4, 5, 6, 2])
        #expect(staging.staged == [2: "RA-020"])
        #expect(staging.unnumbered(in: later).map(\.id) == [7])
    }

    @Test func aChangeTheShelfAlreadyHasIsDropped() {
        var staging = staging(shelf)
        _ = staging.commitTyping("20", for: 2, in: shelf)
        _ = staging.commitTyping("30", for: 4, in: shelf)
        var later = shelf
        later[1] = tape(2, "RA-020")
        staging.follow(later)
        #expect(staging.staged == [4: "RA-030"])
    }

    @Test func oneChangeIsHeadedAsOneReel() {
        var staging = staging(shelf)
        _ = staging.commitTyping("20", for: 2, in: shelf)
        let pending = staging.pending(in: shelf)
        #expect(pending == [.init(tapeID: 2, title: "Reel 2", current: "RA-012", proposed: "RA-020")])
        #expect(pending.heading == "Renumber 1 reel")
        #expect(pending.explanation == "Relabel the boxes to match.")
        #expect(pending.footerNote == "1 proposed change · Awaiting confirmation")
    }

    @Test func twoReelsTradingNumbersAreASwap() {
        var staging = staging(shelf)
        staging.move(from: [1], to: 3, in: shelf)
        let pending = staging.pending(in: shelf)
        #expect(pending.map(\.current) == ["RA-012", "RA-013"])
        #expect(pending.map(\.proposed) == ["RA-013", "RA-012"])
        #expect(pending.heading == "Swap two numbers")
        #expect(pending.explanation == "Apply both changes together. Old site addresses redirect to the new numbers. Update the labels on both boxes afterward.")
        #expect(pending.footerNote == "2 proposed changes · Awaiting confirmation")
    }

    @Test func twoChangesThatDontTradeAreNotASwap() {
        var staging = staging(shelf)
        _ = staging.commitTyping("13", for: 2, in: shelf)
        _ = staging.commitTyping("20", for: 3, in: shelf)
        let pending = staging.pending(in: shelf)
        #expect(pending.heading == "Renumber 2 reels")
        #expect(pending.explanation == "Relabel the boxes to match.")
    }

    @Test func fiveChangesAreCountedAndNoneHasNoHeading() {
        var staging = staging(shelf)
        #expect(staging.pending(in: shelf).heading == nil)
        #expect(staging.pending(in: shelf).footerNote == nil)
        staging.move(from: [0], to: 5, in: shelf)
        #expect(staging.pending(in: shelf).heading == "Renumber 5 reels")
    }
}
