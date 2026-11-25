import Testing
@testable import RemanenceCore

/// The limits that keep a broken layout from freezing the app. The rest of
/// `WaveformTests` is in `ReviewTests.swift`.
extension WaveformTests {
    private static let uneven = Waveform(
        peaks: [60, 90, 200, 255, 120, 80, 45, 44, 46, 130, 180, 240, 100, 70, 50, 210, 220, 90, 60, 55],
        rms: [40, 60, 150, 210, 90, 50, 30, 28, 32, 90, 130, 190, 70, 45, 35, 160, 170, 60, 42, 38]
    )

    @Test func columnsFollowTheWidth() {
        #expect(Waveform.columns(forWidth: 388) == 194)
        #expect(Waveform.columns(forWidth: 389.9) == 194)
        #expect(Waveform.columns(forWidth: 8192) == Waveform.maximumColumns)
    }

    @Test func columnsStayWithinBoundsForAnyWidth() {
        for width in [-100, 0, 1, 3, Double.nan, -Double.infinity] {
            #expect(Waveform.columns(forWidth: width) == 1)
        }
        for width in [34_920_000, Double.greatestFiniteMagnitude, Double.infinity] {
            #expect(Waveform.columns(forWidth: width) == Waveform.maximumColumns)
        }
    }

    @Test func theMarkerCoversItsShareOfTheStrip() {
        #expect(abs(Waveform.markerWidth(of: 90, in: 600, stripWidth: 388) - 58.2) < 0.000001)
        #expect(Waveform.markerWidth(of: 600, in: 600, stripWidth: 388) == 388)
        // A short stretch of a long tape still shows.
        #expect(Waveform.markerWidth(of: 1, in: 3600, stripWidth: 388) == 4)
    }

    @Test func theMarkerIsNeverWiderThanTheStrip() {
        // The values that froze Review: no review loaded, so a length near zero.
        #expect(Waveform.markerWidth(of: 90, in: 0.001, stripWidth: 388) == 388)
        // A tape shorter than the shortest zoom.
        #expect(Waveform.markerWidth(of: 10, in: 2, stripWidth: 388) == 388)
        #expect(Waveform.markerWidth(of: 1, in: 600, stripWidth: 2) == 2)
        #expect(Waveform.markerWidth(of: 90, in: 600, stripWidth: 0) == 0)
        #expect(Waveform.markerWidth(of: 90, in: 0, stripWidth: 388) == 0)
    }

    @Test func levelsNeverReturnMoreThanTheMostColumns() {
        var levels: [Float] = []
        let taken = ContinuousClock().measure {
            levels = Self.uneven.levels(from: 0, to: 0.2, columns: 50_000_000, style: .average)
        }
        #expect(levels.count == Waveform.maximumColumns)
        #expect(taken < .milliseconds(50))
        // The columns still span the whole stretch asked for.
        #expect(levels == Self.uneven.levels(from: 0, to: 0.2, columns: Waveform.maximumColumns, style: .average))
        #expect(levels.last != 0)
    }

    /// Values recorded before the column limit was added.
    @Test(arguments: [
        (0.0, 0.2, 6, Waveform.Style.peak, 0.0, [0.6625767, 1.0, 0.23312883, 0.90797544, 0.72392637, 0.78527606] as [Float]),
        (0.0, 0.2, 6, .peak, 6.0, [0.7966696, 1.0, 0.36722177, 1.0, 0.8580193, 0.919369]),
        (0.0, 0.2, 6, .average, 0.0, [0.02, 0.15132923, 0.02, 0.23312883, 0.02, 0.02]),
        (0.0, 0.2, 6, .average, 6.0, [0.08092316, 0.28542212, 0.02, 0.36722177, 0.060473297, 0.045135874]),
        (0.03, 0.17, 4, .peak, 0.0, [1.0, 0.23312883, 0.90797544, 0.78527606]),
        (0.03, 0.17, 4, .peak, 6.0, [1.0, 0.36722177, 1.0, 0.919369]),
        (0.03, 0.17, 4, .average, 0.0, [0.15132923, 0.02, 0.23312883, 0.064417176]),
        (0.03, 0.17, 4, .average, 6.0, [0.28542212, 0.02, 0.36722177, 0.19851011]),
    ])
    func ordinaryLevelsAreUnchanged(
        start: Double, end: Double, columns: Int, style: Waveform.Style, gain: Double, expected: [Float]
    ) {
        #expect(Self.uneven.levels(from: start, to: end, columns: columns, style: style, gainDB: gain) == expected)
    }
}
