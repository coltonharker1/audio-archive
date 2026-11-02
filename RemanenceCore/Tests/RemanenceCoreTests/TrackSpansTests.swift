import Testing
@testable import RemanenceCore

@Suite struct TrackSpansTests {
    private func ranges(_ spans: [TrackSpan]) -> [[Double]] {
        spans.map { [$0.start, $0.end] }
    }

    @Test func noMarkersMeansOneTrack() {
        let spans = trackSpans(duration: 100, markers: [])
        #expect(ranges(spans) == [[0, 100]])
        #expect(spans[0].startMarker == nil)
    }

    @Test func markersDivideTheSourceInOrder() {
        let spans = trackSpans(duration: 100, markers: [60, 20])
        #expect(ranges(spans) == [[0, 20], [20, 60], [60, 100]])
        #expect(spans.map(\.startMarker) == [nil, 20, 60])
    }

    @Test func trimsBoundTheFirstAndLastTracks() {
        let spans = trackSpans(duration: 100, trimStart: 5, trimEnd: 90, markers: [50])
        #expect(ranges(spans) == [[5, 50], [50, 90]])
    }

    @Test func markersOutsideTheTrimAreIgnored() {
        let spans = trackSpans(duration: 100, trimStart: 10, trimEnd: 90, markers: [5, 10, 50, 90, 95])
        #expect(ranges(spans) == [[10, 50], [50, 90]])
    }

    @Test func duplicateMarkersDoNotCreateEmptyTracks() {
        #expect(ranges(trackSpans(duration: 100, markers: [40, 40])) == [[0, 40], [40, 100]])
    }

    @Test func aTrimLongerThanTheSourceIsClamped() {
        #expect(ranges(trackSpans(duration: 100, trimEnd: 500, markers: [])) == [[0, 100]])
    }

    @Test func anInvertedTrimHasNoTracks() {
        #expect(trackSpans(duration: 100, trimStart: 80, trimEnd: 20, markers: []).isEmpty)
    }
}
