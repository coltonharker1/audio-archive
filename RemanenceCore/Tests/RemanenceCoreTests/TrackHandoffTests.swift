import Testing
@testable import RemanenceCore

@Suite struct TrackHandoffTests {
    /// A piece that plays `start` to `end`, with this much trimmed off around it.
    private static func piece(
        source: Int64 = 1,
        marker: Int64? = nil,
        _ start: Double,
        _ end: Double,
        cutStart: Double = 0,
        cutEnd: Double = 0,
        adjustments: TrackAdjustments = .none
    ) -> PostTrack {
        var track = PostTrack(
            sourceID: source, startMarkerID: marker, name: nil, description: nil,
            start: start, end: end, summaryShort: nil, summaryLong: nil, adjustments: adjustments
        )
        track.cutStart = cutStart
        track.cutEnd = cutEnd
        return track
    }

    /// Three tracks on one side, kept from 0:05 to 1:42.
    private static let tracks = [
        piece(5, 34),
        piece(marker: 1, 34, 70),
        piece(marker: 2, 70, 102),
    ]

    private func arrive(
        _ time: Double, source: Int64 = 1, in tracks: [PostTrack] = tracks
    ) throws -> TrackHandoff.Arrival {
        try #require(TrackHandoff.arrival(sourceID: source, time: time, in: tracks))
    }

    @Test func timeInsideATrackOpensItThere() throws {
        let arrival = try arrive(42)
        #expect(arrival.piece.startMarkerID == 1)
        #expect(arrival.time == 42)
    }

    @Test func timeOnAMarkerOpensTheTrackItStarts() throws {
        let arrival = try arrive(34)
        #expect(arrival.piece.startMarkerID == 1)
        #expect(arrival.time == 34)
    }

    @Test func playheadJustShortOfAMarkerCountsAsOnIt() throws {
        let arrival = try arrive(33.9983)
        #expect(arrival.piece.startMarkerID == 1)
        #expect(arrival.time == 34)
        #expect(try arrive(33.9).piece.startMarkerID == nil)
    }

    /// Review's note names the track at its coarse time. Just past a marker the
    /// player is already on the next, and Edit must still open the one named.
    @Test func aHandoffJustPastAMarkerOpensTheTrackTheScreenNames() throws {
        let starts = Self.tracks.map(\.spanStart)
        let time = TrackHandoff.time(34.2, onTrackAt: 33.9, starts: starts)
        #expect(time < 34)
        #expect(time > 33.9)
        #expect(try arrive(time).piece.startMarkerID == nil)
    }

    @Test func aHandoffOnTheNamedTrackKeepsThePreciseTime() {
        let starts = Self.tracks.map(\.spanStart)
        #expect(TrackHandoff.time(42.37, onTrackAt: 42.2, starts: starts) == 42.37)
        // Caught up to the marker, both name the later track.
        #expect(TrackHandoff.time(34.2, onTrackAt: 34, starts: starts) == 34.2)
        // On the last track there's no later one to stay short of.
        #expect(TrackHandoff.time(101, onTrackAt: 100.8, starts: starts) == 101)
        #expect(TrackHandoff.time(12, onTrackAt: 11.8, starts: []) == 12)
    }

    @Test func trimmedOffPartsGoToTheNearestKeptEdge() throws {
        // The first track leaves out its last four seconds, the second its first two.
        let tracks = [
            Self.piece(0, 30, cutEnd: 4),
            Self.piece(marker: 1, 36, 70, cutStart: 2),
        ]
        let tail = try arrive(32, in: tracks)
        #expect(tail.piece.startMarkerID == nil)
        #expect(tail.time == 30)
        let head = try arrive(35, in: tracks)
        #expect(head.piece.startMarkerID == 1)
        #expect(head.time == 36)
    }

    @Test func beforeTheSideTrimGoesToTheFirstTrack() throws {
        let arrival = try arrive(1)
        #expect(arrival.piece.startMarkerID == nil)
        #expect(arrival.time == 5)
    }

    @Test func afterTheSideTrimGoesToTheLastTrack() throws {
        let arrival = try arrive(110)
        #expect(arrival.piece.startMarkerID == 2)
        #expect(arrival.time == 102)
    }

    @Test func orderOfTheTracksDoesNotMatter() throws {
        let reordered = [Self.tracks[2], Self.tracks[0], Self.tracks[1]]
        #expect(try arrive(42, in: reordered).piece.startMarkerID == 1)
        #expect(try arrive(1, in: reordered).piece.startMarkerID == nil)
    }

    @Test func appendedPieceIsFoundAsItsOwnPiece() throws {
        // The side's third track plays after the first, so it isn't in the list itself.
        var head = Self.tracks[0]
        head.continuations = [Self.tracks[2]]
        let tracks = [head, Self.tracks[1]]
        let arrival = try arrive(80, in: tracks)
        #expect(arrival.piece.startMarkerID == 2)
        #expect(arrival.piece.continuations.isEmpty)
        #expect(arrival.time == 80)
        // The track it's appended to is found as itself alone.
        let first = try arrive(10, in: tracks)
        #expect(first.piece.id == head.id)
        #expect(first.piece.continuations.isEmpty)
    }

    @Test func pieceAppendedFromAnotherSideIsFound() throws {
        var head = Self.piece(0, 50)
        head.continuations = [Self.piece(source: 2, marker: 4, 20, 40)]
        let tracks = [head, Self.piece(source: 2, 0, 20)]
        let arrival = try arrive(25, source: 2, in: tracks)
        #expect(arrival.piece.startMarkerID == 4)
        #expect(arrival.time == 25)
    }

    @Test func reversedTrackKeepsMasterTime() throws {
        let reversed = Self.piece(marker: 1, 34, 70, adjustments: TrackAdjustments(speed: 0.5, reversed: true))
        let arrival = try arrive(42, in: [Self.tracks[0], reversed])
        #expect(arrival.time == 42)
        #expect(TrackHandoff.place(in: arrival.piece, at: arrival.time) == .init(sourceID: 1, time: 42))
        // It starts playing at its far end, which is still inside it on the way back.
        let back = TrackHandoff.place(in: reversed, at: reversed.end)
        #expect(back.time < reversed.end)
        #expect(try arrive(back.time, in: [reversed, Self.tracks[2]]).piece.id == reversed.id)
    }

    @Test func eachSideFindsItsOwnTracks() throws {
        let tracks = Self.tracks + [Self.piece(source: 2, 0, 40), Self.piece(source: 2, marker: 5, 40, 90)]
        #expect(try arrive(42, source: 1, in: tracks).piece.id == "1-1")
        #expect(try arrive(42, source: 2, in: tracks).piece.id == "2-5")
    }

    @Test func recordingWithNoTracksGivesNil() {
        #expect(TrackHandoff.arrival(sourceID: 9, time: 42, in: Self.tracks) == nil)
        #expect(TrackHandoff.arrival(sourceID: 1, time: 42, in: []) == nil)
    }

    @Test(arguments: [5.0, 20, 34, 42, 69.5, 70, 101])
    func roundTripReturnsToTheSameMoment(time: Double) throws {
        let there = try arrive(time)
        let back = TrackHandoff.place(in: there.piece, at: there.time)
        #expect(back == .init(sourceID: 1, time: time))
        #expect(try arrive(back.time).piece.id == there.piece.id)
    }

    @Test func movingInEditReturnsToWhereItMoved() throws {
        let there = try arrive(42)
        #expect(TrackHandoff.place(in: there.piece, at: 46) == .init(sourceID: 1, time: 46))
    }

    @Test func returnStaysInsideThePiece() throws {
        let piece = Self.tracks[1]
        #expect(TrackHandoff.place(in: piece, at: 0).time == 34)
        #expect(TrackHandoff.place(in: piece, at: .nan).time == 34)
        let end = TrackHandoff.place(in: piece, at: 500)
        #expect(end.time == 70 - TrackHandoff.inset)
        #expect(try arrive(end.time).piece.id == piece.id)
    }

    @Test func zoomHoldingTheTimeStaysPut() {
        #expect(TrackHandoff.zoomStart(30, span: 20, showing: 46, duration: 102) == 30)
        #expect(TrackHandoff.zoomStart(30, span: 20, showing: 50, duration: 102) == 30)
    }

    @Test func zoomMissingTheTimeCentresOnIt() {
        #expect(TrackHandoff.zoomStart(30, span: 20, showing: 70, duration: 102) == 60)
        #expect(TrackHandoff.zoomStart(30, span: 20, showing: 2, duration: 102) == 0)
        #expect(TrackHandoff.zoomStart(30, span: 20, showing: 101, duration: 102) == 82)
    }

    @Test func returnButtonNamesTheSide() {
        #expect(TrackHandoff.returnTitle(side: "A") == "Return to Side A")
        #expect(TrackHandoff.returnTitle(side: nil) == "Return to Review")
        #expect(TrackHandoff.returnTitle(side: "") == "Return to Review")
        #expect(TrackHandoff.returnTitle(side: "The long second one") == "Return to Side The long se…")
    }
}
