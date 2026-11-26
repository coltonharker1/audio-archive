import Foundation
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

    // MARK: Against the old maths

    /// `Waveform.levels` as it was before it was rewritten for speed. It's the
    /// reference for the new one, so leave its arithmetic alone.
    private static func referenceLevels(
        _ wave: Waveform, from start: Double, to end: Double, columns: Int, style: Waveform.Style, gainDB: Double
    ) -> [Float] {
        let peaks = wave.peaks
        let rms = wave.rms
        guard columns > 0, end > start, !peaks.isEmpty else { return [] }
        let columns = min(columns, Waveform.maximumColumns)
        let binsPerColumn = (end - start) * Double(Waveform.binsPerSecond) / Double(columns)
        let floor = Float(wave.quietLevel)
        let range = max(1, 255 - floor)
        let stepsPerDecibel: Float = 255 / 70

        return (0..<columns).map { column in
            let first = Int(start * Double(Waveform.binsPerSecond) + Double(column) * binsPerColumn)
            let last = Int(start * Double(Waveform.binsPerSecond) + Double(column + 1) * binsPerColumn)
            guard first >= 0, first < peaks.count else { return 0 }
            let bins = first...min(max(first, last - 1), peaks.count - 1)

            let value: Float
            switch style {
            case .peak:
                var largest: UInt8 = 0
                for index in bins where peaks[index] > largest { largest = peaks[index] }
                value = Float(largest)
            case .average:
                var total = 0
                for index in bins { total += Int(rms[index]) }
                value = Float(total) / Float(bins.count)
            }
            let adjusted = min(255, value + Float(gainDB) * stepsPerDecibel)
            return max(0.02, min(1, (adjusted - floor) / range))
        }
    }

    /// The same numbers on every run, so a failure can be repeated.
    private struct SeededNumbers: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    /// Compares bit patterns, which is stricter than `==` on the numbers.
    private static func matchesReference(
        _ wave: Waveform, from start: Double, to end: Double, columns: Int, style: Waveform.Style, gainDB: Double
    ) -> Bool {
        let new = wave.levels(from: start, to: end, columns: columns, style: style, gainDB: gainDB)
        let old = referenceLevels(wave, from: start, to: end, columns: columns, style: style, gainDB: gainDB)
        return new.map(\.bitPattern) == old.map(\.bitPattern)
    }

    @Test func levelsMatchTheOldMathsOnRandomWaveforms() {
        var numbers = SeededNumbers(state: 1)
        for round in 0..<600 {
            let count = Int.random(in: 1...3000, using: &numbers)
            // Floors from silent to nearly full scale, where the range runs out.
            let lowest = UInt8.random(in: 0...255, using: &numbers)
            let peaks = (0..<count).map { _ in UInt8.random(in: lowest...255, using: &numbers) }
            let rms = (0..<count).map { _ in UInt8.random(in: lowest...255, using: &numbers) }
            let wave = Waveform(peaks: peaks, rms: rms)

            // Stretches that begin before the audio or run past its end, too.
            let start = Double.random(in: -2...(wave.duration + 2), using: &numbers)
            let end = start + Double.random(in: 0.0001...(wave.duration + 3), using: &numbers)
            let columns = Int.random(in: 1...900, using: &numbers)
            let gain = Bool.random(using: &numbers) ? 0 : Double.random(in: -80...80, using: &numbers)
            for style in [Waveform.Style.peak, .average] {
                #expect(
                    Self.matchesReference(wave, from: start, to: end, columns: columns, style: style, gainDB: gain),
                    "round \(round): \(count) bins, \(start) to \(end), \(columns) columns, \(style), \(gain) dB"
                )
            }
        }
    }

    @Test func levelsMatchTheOldMathsAtTheEdges() {
        let wave = Self.uneven
        let stretches: [(Double, Double)] = [
            (0, 0.2), (0, wave.duration), (-1, 0.1), (-0.005, 0.2), (0.19, 0.2), (0.2, 0.4), (5, 6),
            (0.1, 0.1), (0.2, 0.1), (0, 0.000001), (0.07, 0.0700001),
        ]
        let gains: [Double] = [0, 6, -6, 1000, -1000, .infinity, -.infinity, .nan]
        for (start, end) in stretches {
            for columns in [-1, 0, 1, 2, 19, 20, 21, 4096, 4097, 1_000_000] {
                for style in [Waveform.Style.peak, .average] {
                    for gain in gains {
                        #expect(
                            Self.matchesReference(wave, from: start, to: end, columns: columns, style: style, gainDB: gain),
                            "\(start) to \(end), \(columns) columns, \(style), \(gain) dB"
                        )
                    }
                }
            }
        }
        let empty = Waveform(peaks: [], rms: [])
        #expect(empty.levels(from: 0, to: 1, columns: 4).isEmpty)
    }

    /// A waveform made the way a recording's is: decoded audio, saved and read back.
    @Test func levelsMatchTheOldMathsOnAWaveformReadFromAudio() throws {
        var numbers = SeededNumbers(state: 2)
        // Two minutes of loud stretches and hiss, with a click now and then.
        var samples: [Int16] = []
        for second in 0..<120 {
            let loudness: Int16 = second % 7 < 5 ? Int16.random(in: 2000...20000, using: &numbers) : 40
            for _ in 0..<8000 { samples.append(Int16.random(in: -loudness...loudness, using: &numbers)) }
            if second % 11 == 0 { samples[samples.count - 3000] = .max }
        }
        let url = TestFolders.file("wave.raw")
        defer { try? FileManager.default.removeItem(at: url) }
        try samples.withUnsafeBytes { Data($0) }.write(to: url)
        let wave = try Waveform(encoded: Waveform(decodedAudioAt: url).encoded())
        #expect(wave.peaks.count == 12_000)

        for columns in [1, 194, 430, 777] {
            for style in [Waveform.Style.peak, .average] {
                for gain in [0.0, -12, 4.5] {
                    #expect(Self.matchesReference(wave, from: 0, to: wave.duration, columns: columns, style: style, gainDB: gain))
                    for step in 0..<25 {
                        let start = Double(step) * 4.7131
                        #expect(Self.matchesReference(
                            wave, from: start, to: start + 10.3, columns: columns, style: style, gainDB: gain
                        ))
                    }
                }
            }
        }
    }

    @Test(arguments: [Waveform.Style.peak, .average])
    func levelsForATenMinuteTapeAreQuick(style: Waveform.Style) {
        let bins = (0..<60_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let wave = Waveform(peaks: bins, rms: bins)
        let clock = ContinuousClock()
        var count = 0
        // The best of several, so other tests running alongside don't count.
        let best = (0..<10).map { _ in
            clock.measure { count = wave.levels(from: 0, to: 600, columns: 430, style: style).count }
        }.min()!
        print("levels, 60,000 bins, 430 columns, \(style): \(best)")
        #expect(count == 430)
        // Under 2 ms in a Debug build, with room for a slower machine. The old
        // maths took over 25 ms.
        #expect(best < .milliseconds(8), "took \(best)")
    }

    // MARK: The cache

    private static let other = Waveform(peaks: uneven.peaks.reversed(), rms: uneven.rms.reversed())

    @Test func theCacheReturnsWhatTheWaveformWould() {
        let cache = WaveformLevelsCache()
        for style in [Waveform.Style.peak, .average] {
            for gain in [0.0, 6] {
                let direct = Self.uneven.levels(from: 0.03, to: 0.17, columns: 4, style: style, gainDB: gain)
                for _ in 0..<2 {
                    let cached = cache.levels(of: Self.uneven, from: 0.03, to: 0.17, columns: 4, style: style, gainDB: gain)
                    #expect(cached == direct)
                }
            }
        }
        #expect(cache.counts == (hits: 4, misses: 4))
    }

    @Test func theCacheHitsOnARepeatedRequest() {
        let cache = WaveformLevelsCache()
        let first = cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 6)
        // An equal waveform loaded separately counts as the same one.
        let copy = Waveform(peaks: Self.uneven.peaks.map { $0 }, rms: Self.uneven.rms.map { $0 })
        #expect(cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 6) == first)
        #expect(cache.levels(of: copy, from: 0, to: 0.2, columns: 6) == first)
        // The defaults are the same request as spelling them out.
        #expect(cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 6, style: .peak, gainDB: 0) == first)
        #expect(cache.counts == (hits: 3, misses: 1))
        #expect(cache.entryCount == 1)
    }

    @Test(arguments: [
        (0.01, 0.2, 6, Waveform.Style.peak, 0.0),
        (0.0, 0.19, 6, .peak, 0.0),
        (0.0, 0.2, 5, .peak, 0.0),
        (0.0, 0.2, 6, .average, 0.0),
        (0.0, 0.2, 6, .peak, 6.0),
    ])
    func theCacheMissesWhenAnyPartOfTheRequestDiffers(
        start: Double, end: Double, columns: Int, style: Waveform.Style, gain: Double
    ) {
        let cache = WaveformLevelsCache()
        _ = cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 6)
        let levels = cache.levels(of: Self.uneven, from: start, to: end, columns: columns, style: style, gainDB: gain)
        #expect(levels == Self.uneven.levels(from: start, to: end, columns: columns, style: style, gainDB: gain))
        #expect(cache.counts == (hits: 0, misses: 2))
        // Both are still held.
        _ = cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 6)
        #expect(cache.counts == (hits: 1, misses: 2))
    }

    @Test func theCacheForgetsEverythingWhenTheWaveformChanges() {
        let cache = WaveformLevelsCache()
        let before = cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 6)
        _ = cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 4)

        let after = cache.levels(of: Self.other, from: 0, to: 0.2, columns: 6)
        #expect(after == Self.other.levels(from: 0, to: 0.2, columns: 6))
        #expect(after != before)
        #expect(cache.counts == (hits: 0, misses: 3))
        #expect(cache.entryCount == 1)

        // Going back works them out again.
        #expect(cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 6) == before)
        #expect(cache.counts == (hits: 0, misses: 4))
    }

    /// A change to only one of the two sets of levels still makes a different waveform.
    @Test func theCacheNoticesAChangeToOnlyOneSetOfLevels() {
        var rms = Self.uneven.rms
        rms[3] = 40
        let changed = Waveform(peaks: Self.uneven.peaks, rms: rms)
        let cache = WaveformLevelsCache()
        _ = cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 6, style: .average)
        let levels = cache.levels(of: changed, from: 0, to: 0.2, columns: 6, style: .average)
        #expect(levels == changed.levels(from: 0, to: 0.2, columns: 6, style: .average))
        #expect(cache.counts == (hits: 0, misses: 2))
    }

    @Test func theCacheCanBeCleared() {
        let cache = WaveformLevelsCache()
        _ = cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 6)
        cache.removeAll()
        #expect(cache.entryCount == 0)
        _ = cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 6)
        #expect(cache.counts == (hits: 0, misses: 2))
    }

    @Test func theCacheStaysWithinItsLimit() {
        let cache = WaveformLevelsCache()
        for columns in 1...100 {
            _ = cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: columns)
            #expect(cache.entryCount == min(columns, WaveformLevelsCache.capacity))
        }
    }

    /// Panning the close-up asks for a new stretch each time, between redraws of the
    /// whole side, which must stay held.
    @Test func theCacheDropsTheLeastRecentlyUsed() {
        let cache = WaveformLevelsCache()
        _ = cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 6, style: .average)
        for pan in 1...50 {
            _ = cache.levels(of: Self.uneven, from: Double(pan) / 1000, to: 0.2, columns: 6)
            _ = cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 6, style: .average)
        }
        #expect(cache.counts == (hits: 50, misses: 51))
        // The first pan is long gone.
        _ = cache.levels(of: Self.uneven, from: 0.001, to: 0.2, columns: 6)
        #expect(cache.counts == (hits: 50, misses: 52))
    }

    @Test func askingForTooManyColumnsSharesTheCappedEntry() {
        let cache = WaveformLevelsCache()
        let capped = cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: Waveform.maximumColumns)
        #expect(cache.levels(of: Self.uneven, from: 0, to: 0.2, columns: 50_000_000) == capped)
        #expect(cache.counts == (hits: 1, misses: 1))
    }

    @Test func theCacheIsSafeToShareBetweenThreads() async {
        let cache = WaveformLevelsCache()
        let waves = [Self.uneven, Self.other]
        let wrong = await withTaskGroup(of: Int.self) { group in
            for task in 0..<8 {
                group.addTask {
                    var wrong = 0
                    for step in 0..<200 {
                        let wave = waves[(task + step / 50) % 2]
                        let columns = 1 + (task + step) % 12
                        let cached = cache.levels(of: wave, from: 0, to: 0.2, columns: columns)
                        if cached != wave.levels(from: 0, to: 0.2, columns: columns) { wrong += 1 }
                        if step % 70 == 0 { cache.removeAll() }
                    }
                    return wrong
                }
            }
            return await group.reduce(0, +)
        }
        #expect(wrong == 0)
        #expect(cache.counts.hits + cache.counts.misses == 1600)
        #expect(cache.entryCount <= WaveformLevelsCache.capacity)
    }
}
