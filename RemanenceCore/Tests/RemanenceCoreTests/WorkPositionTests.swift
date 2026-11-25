import Foundation
import Testing
@testable import RemanenceCore

@Suite struct WorkPositionTests {
    private static func tape(uuid: String = "tape-1", sides: [(id: Int64, side: String?, duration: Double)] = [(1, "A", 102), (2, "B", 60)]) -> ShelfTape {
        let items = sides.enumerated().map { index, side in
            var source = Source(tapeId: 1, position: index, masterPath: "masters/\(side.id).wav", duration: side.duration)
            source.id = side.id
            source.side = side.side
            return ShelfTape.Item(source: source, name: "Recording \(index + 1)")
        }
        return ShelfTape(tape: Tape(uuid: uuid, title: "Station break", createdAt: Date()), items: items)
    }

    private static func position(
        sourceID: Int64 = 2,
        playhead: Double = 42,
        zoomStart: Double? = 30,
        zoomSpan: Double? = 20,
        editTrackID: String? = nil
    ) -> WorkPosition {
        WorkPosition(
            tapeUUID: "tape-1", tab: .review, sourceID: sourceID, playhead: playhead,
            zoomStart: zoomStart, zoomSpan: zoomSpan, editTrackID: editTrackID
        )
    }

    @Test(arguments: [WorkPosition.Tab.review, .edit, .readAlong, .post])
    func roundTrip(tab: WorkPosition.Tab) throws {
        var saved = Self.position(editTrackID: "2-7")
        saved.tab = tab
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(WorkPosition.self, from: data) == saved)
    }

    @Test func positionThatStillFitsIsUnchanged() throws {
        let saved = Self.position(editTrackID: "2-7")
        let resolved = try #require(saved.resolved(in: [Self.tape(uuid: "other"), Self.tape()]))
        #expect(resolved.tape.tape.uuid == "tape-1")
        #expect(resolved.itemIndex == 1)
        #expect(resolved.item.source.id == 2)
        #expect(resolved.position == saved)
    }

    @Test func unknownTapeGivesNil() {
        #expect(Self.position().resolved(in: [Self.tape(uuid: "other")]) == nil)
        #expect(Self.position().resolved(in: []) == nil)
    }

    @Test func tapeWithNoRecordingsGivesNil() {
        #expect(Self.position().resolved(in: [Self.tape(sides: [])]) == nil)
    }

    @Test func removedSideFallsBackToTheFirstSideAtTheStart() throws {
        let saved = Self.position(sourceID: 9, editTrackID: "9-0")
        let resolved = try #require(saved.resolved(in: [Self.tape()]))
        #expect(resolved.itemIndex == 0)
        #expect(resolved.position == WorkPosition(tapeUUID: "tape-1", tab: .review, sourceID: 1, playhead: 0))
    }

    @Test(arguments: [(500.0, 60.0), (-3, 0), (60, 60), (.nan, 0), (.infinity, 0)])
    func playheadStaysWithinTheRecording(saved: Double, expected: Double) throws {
        let resolved = try #require(Self.position(playhead: saved).resolved(in: [Self.tape()]))
        #expect(resolved.position.playhead == expected)
    }

    @Test func zoomWiderThanTheSideClamps() throws {
        let resolved = try #require(Self.position(zoomStart: 10, zoomSpan: 90).resolved(in: [Self.tape()]))
        #expect(resolved.position.zoomSpan == 60)
        #expect(resolved.position.zoomStart == 0)
    }

    @Test func zoomPastTheEndMovesBack() throws {
        let resolved = try #require(Self.position(zoomStart: 55, zoomSpan: 20).resolved(in: [Self.tape()]))
        #expect(resolved.position.zoomSpan == 20)
        #expect(resolved.position.zoomStart == 40)
    }

    @Test func zoomNeverGoesCloserThanReviewDoes() throws {
        let resolved = try #require(Self.position(zoomStart: -5, zoomSpan: 1).resolved(in: [Self.tape()]))
        #expect(resolved.position.zoomSpan == WorkPosition.minimumZoomSpan)
        #expect(resolved.position.zoomStart == 0)
    }

    @Test func sideShorterThanTheClosestZoomShowsWhole() throws {
        let tape = Self.tape(sides: [(2, nil, 2.5)])
        let resolved = try #require(Self.position(playhead: 1).resolved(in: [tape]))
        #expect(resolved.position.zoomSpan == 2.5)
        #expect(resolved.position.zoomStart == 0)
    }

    @Test func halfAZoomIsDropped() throws {
        let resolved = try #require(Self.position(zoomSpan: nil).resolved(in: [Self.tape()]))
        #expect(resolved.position.zoomStart == nil)
        #expect(resolved.position.zoomSpan == nil)
    }

    @Test func missingOptionalFieldsDecode() throws {
        let json = #"{"tapeUUID":"tape-1","tab":"readAlong","sourceID":2,"playhead":4.5}"#
        let decoded = try JSONDecoder().decode(WorkPosition.self, from: Data(json.utf8))
        #expect(decoded == WorkPosition(tapeUUID: "tape-1", tab: .readAlong, sourceID: 2, playhead: 4.5))
    }

    @Test func buttonNamesTheSide() throws {
        let resolved = try #require(Self.position().resolved(in: [Self.tape()]))
        #expect(resolved.buttonTitle == "Resume Side B")
    }

    @Test func buttonForAnUnnamedRecordingSaysOnlyResume() throws {
        let resolved = try #require(Self.position().resolved(in: [Self.tape(sides: [(2, nil, 60)])]))
        #expect(resolved.buttonTitle == "Resume")
    }

    @Test func buttonCutsALongSideName() throws {
        let tape = Self.tape(sides: [(2, "The long second half of it", 60)])
        let resolved = try #require(Self.position().resolved(in: [tape]))
        #expect(resolved.buttonTitle == "Resume Side The long second…")
    }
}
