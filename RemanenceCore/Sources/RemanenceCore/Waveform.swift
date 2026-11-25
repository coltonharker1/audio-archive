import Foundation

/// A compact summary of a recording's loudness over time, cached to disk so even a
/// long tape can be drawn and scrubbed instantly.
public struct Waveform: Equatable, Sendable {
    static let decodeRate = 8000
    public static let binsPerSecond = 100
    private static let samplesPerBin = decodeRate / binsPerSecond
    private static let magic = Data("RMWF1".utf8)

    /// Levels on a decibel scale, from 0 at -70 dB to 255 at full scale. A decibel
    /// scale keeps quiet speech and tape hiss visible, which matters for placing
    /// markers in gaps.
    public let peaks: [UInt8]
    let rms: [UInt8]

    /// How loud "quiet" is on this tape, taken from its own noise floor, because
    /// floors differ by over 15 dB between your tapes.
    let quietLevel: UInt8

    /// Stretches of quiet, in bins, worked out once when the waveform loads.
    private let quietRuns: [ClosedRange<Int>]

    public var duration: Double { Double(peaks.count) / Double(Self.binsPerSecond) }

    public enum WaveformError: LocalizedError {
        case unreadable

        public var errorDescription: String? { "The waveform data couldn’t be read." }
    }

    init(peaks: [UInt8], rms: [UInt8]) {
        self.peaks = peaks
        self.rms = rms
        let smoothed = Self.smoothed(rms)
        quietLevel = Self.quietLevel(of: smoothed)
        quietRuns = Self.quietRuns(in: smoothed, level: quietLevel)
    }

    /// Averages levels over about 100 ms. Even a real gap is spiky at 10 ms, where
    /// tape noise keeps crossing any threshold.
    private static func smoothed(_ rms: [UInt8]) -> [UInt8] {
        guard !rms.isEmpty else { return [] }
        var totals = [Int](repeating: 0, count: rms.count + 1)
        for (index, value) in rms.enumerated() { totals[index + 1] = totals[index] + Int(value) }
        return rms.indices.map { index in
            let first = max(0, index - 5)
            let last = min(rms.count, index + 5)
            return UInt8((totals[last] - totals[first]) / max(1, last - first))
        }
    }

    /// Finds quiet stretches, bridging blips under 0.3 s such as a click or a breath,
    /// and ignoring anything too short to be a real gap.
    private static func quietRuns(in levels: [UInt8], level: UInt8) -> [ClosedRange<Int>] {
        let bridge = 30
        let minimum = 25
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        var lastQuiet = 0
        for (index, value) in levels.enumerated() where value <= level {
            if let current = start, index - lastQuiet - 1 > bridge {
                if lastQuiet - current + 1 >= minimum { runs.append(current...lastQuiet) }
                start = index
            } else if start == nil {
                start = index
            }
            lastQuiet = index
        }
        if let start, lastQuiet - start + 1 >= minimum { runs.append(start...lastQuiet) }
        return runs
    }

    /// Reads 16-bit mono audio at `decodeRate` in pieces, so memory stays low.
    init(decodedAudioAt url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var peaks: [UInt8] = []
        var rms: [UInt8] = []
        let chunkBins = 6000
        let chunkBytes = chunkBins * Self.samplesPerBin * 2
        var carry = Data()

        while true {
            let more: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty else { return false }
                var data = carry
                data.append(chunk)
                let usable = data.count - data.count % (Self.samplesPerBin * 2)
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let samples = raw.bindMemory(to: Int16.self)
                    var index = 0
                    let total = usable / 2
                    while index < total {
                        var largest: Int32 = 0
                        var sum: Int64 = 0
                        for offset in index..<(index + Self.samplesPerBin) {
                            let value = Int32(Int16(littleEndian: samples[offset]))
                            let magnitude = abs(value)
                            if magnitude > largest { largest = magnitude }
                            sum += Int64(value) * Int64(value)
                        }
                        peaks.append(Self.level(Double(largest) / 32768))
                        rms.append(Self.level((Double(sum) / Double(Self.samplesPerBin)).squareRoot() / 32768))
                        index += Self.samplesPerBin
                    }
                }
                carry = data.subdata(in: usable..<data.count)
                return true
            }
            if !more { break }
        }
        self.init(peaks: peaks, rms: rms)
    }

    private static func level(_ amplitude: Double) -> UInt8 {
        guard amplitude > 0 else { return 0 }
        let decibels = 20 * log10(amplitude)
        return UInt8(max(0, min(255, ((decibels + 70) / 70 * 255).rounded())))
    }

    private static func quietLevel(of rms: [UInt8]) -> UInt8 {
        guard !rms.isEmpty else { return 0 }
        var histogram = [Int](repeating: 0, count: 256)
        for value in rms { histogram[Int(value)] += 1 }
        // A low percentile finds the true floor even on a tape with few gaps, where
        // anything higher would land in the audio and make it all count as quiet.
        let target = rms.count / 100
        var seen = 0
        var floor = 255
        for (level, count) in histogram.enumerated() {
            seen += count
            if seen > target {
                floor = level
                break
            }
        }
        // Six decibels above the floor, in the 0 to 255 scale.
        return UInt8(min(255, floor + 22))
    }

    public func encoded() -> Data {
        var data = Self.magic
        var count = UInt32(peaks.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(contentsOf: peaks)
        data.append(contentsOf: rms)
        return data
    }

    public init(encoded data: Data) throws {
        let header = Self.magic.count + 4
        guard data.count >= header, data.prefix(Self.magic.count) == Self.magic else {
            throw WaveformError.unreadable
        }
        let bytes = [UInt8](data)
        var count = 0
        for offset in 0..<4 {
            count |= Int(bytes[Self.magic.count + offset]) << (offset * 8)
        }
        guard bytes.count == header + count * 2 else { throw WaveformError.unreadable }
        self.init(
            peaks: Array(bytes[header..<(header + count)]),
            rms: Array(bytes[(header + count)...])
        )
    }

    public enum Style: Sendable {
        /// Each column shows its loudest moment, so short sounds don't vanish.
        case peak
        /// Each column shows its typical level, so gaps show up across a long tape.
        /// A single loud moment would otherwise fill in every gap around it.
        case average
    }

    /// The most columns ever worked out or drawn at once. No real window is wide
    /// enough to reach it, so it only limits the damage a broken layout can do.
    public static let maximumColumns = 4096

    /// How many columns, two points apart, to draw across a width: at least one and
    /// never more than `maximumColumns`.
    public static func columns(forWidth width: Double) -> Int {
        let half = width / 2
        guard half > 1 else { return 1 }
        return Int(min(half, Double(maximumColumns)))
    }

    /// The width of the box marking a stretch of the tape on a strip showing all of
    /// it: wide enough to see, but never wider than the strip, which would stretch
    /// everything laid out with it.
    public static func markerWidth(of span: Double, in duration: Double, stripWidth: Double) -> Double {
        guard duration > 0 else { return 0 }
        return max(0, min(stripWidth, max(4, stripWidth * span / duration)))
    }

    /// Levels from 0 to 1 for drawing a stretch of the tape in a given number of
    /// columns, scaled against this tape's noise floor so hiss sits near zero and
    /// gaps are easy to see.
    ///
    /// `gainDB` draws it as it will sound with a level change, against the same floor.
    /// No more than `maximumColumns` are returned, however many are asked for.
    public func levels(from start: Double, to end: Double, columns: Int, style: Style = .peak, gainDB: Double = 0) -> [Float] {
        guard columns > 0, end > start, !peaks.isEmpty else { return [] }
        let columns = min(columns, Self.maximumColumns)
        let binsPerColumn = (end - start) * Double(Self.binsPerSecond) / Double(columns)
        let floor = Float(quietLevel)
        let range = max(1, 255 - floor)

        // Plain loops over raw buffers: the app is run as a Debug build, where
        // iterating ranges is slow enough to make dragging stutter.
        let source = style == .peak ? peaks : rms
        let count = peaks.count
        var result = [Float](repeating: 0, count: columns)
        result.withUnsafeMutableBufferPointer { output in
            source.withUnsafeBufferPointer { input in
                var column = 0
                while column < columns {
                    let first = Int(start * Double(Self.binsPerSecond) + Double(column) * binsPerColumn)
                    let last = Int(start * Double(Self.binsPerSecond) + Double(column + 1) * binsPerColumn)
                    // A column outside the audio stays at zero.
                    guard first >= 0, first < count else {
                        column += 1
                        continue
                    }
                    let end = min(max(first, last - 1), count - 1) + 1
                    precondition(end <= input.count)

                    var index = first
                    let value: Float
                    switch style {
                    case .peak:
                        var largest: UInt8 = 0
                        while index < end {
                            let bin = input[index]
                            if bin > largest { largest = bin }
                            index += 1
                        }
                        value = Float(largest)
                    case .average:
                        var total = 0
                        while index < end {
                            total += Int(input[index])
                            index += 1
                        }
                        value = Float(total) / Float(end - first)
                    }
                    let adjusted = min(255, value + Float(gainDB) * Self.stepsPerDecibel)
                    output[column] = max(0.02, min(1, (adjusted - floor) / range))
                    column += 1
                }
            }
        }
        return result
    }

    /// Levels are stored from -70 dB at 0 to full scale at 255.
    private static let stepsPerDecibel: Float = 255 / 70

    /// The loudest moment in a stretch, in decibels below full scale. It's measured on
    /// the waveform's reduced copy of the audio, so the real peak can be a little higher.
    public func loudestPeak(from start: Double, to end: Double) -> Double? {
        let first = max(0, Int(start * Double(Self.binsPerSecond)))
        let last = min(peaks.count, Int(end * Double(Self.binsPerSecond)))
        guard last > first, let loudest = peaks[first..<last].max() else { return nil }
        return Double(Float(loudest) / Self.stepsPerDecibel) - 70
    }

    /// The closest quiet moment to a time, for placing a marker between sounds.
    /// A time already in a quiet stretch stays put. Returns nil when nothing nearby
    /// is quiet, so a marker is never pulled somewhere arbitrary.
    public func nearestQuiet(to time: Double, within reach: Double = 3) -> Double? {
        let rate = Double(Self.binsPerSecond)
        let center = Int(time * rate)
        var best: Double?

        for run in quietRuns {
            if run.contains(center) { return time }

            // Land a little inside the quiet, rather than right on its edge.
            let margin = min(15, (run.upperBound - run.lowerBound) / 2)
            let candidate = Double(center < run.lowerBound ? run.lowerBound + margin : run.upperBound - margin) / rate
            let distance = abs(candidate - time)
            if distance <= reach, best.map({ abs($0 - time) > distance }) ?? true {
                best = candidate
            }
        }
        return best
    }
}
