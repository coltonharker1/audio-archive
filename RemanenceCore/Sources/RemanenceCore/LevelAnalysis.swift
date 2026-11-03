import Foundation

/// What to tell you about the level coming in.
public enum LevelAdvice: Equatable, Sendable {
    case noSignal
    case tooQuiet
    case fine
    case good
    case hot
    case clipping

    /// Thresholds are provisional until tested on real machines through the Scarlett.
    public static func assess(peak: Double, clipped: Bool) -> LevelAdvice {
        if clipped || peak >= -0.1 { return .clipping }
        if peak > -3 { return .hot }
        if peak >= -12 { return .good }
        if peak >= -40 { return .fine }
        if peak >= -65 { return .tooQuiet }
        return .noSignal
    }
}

public func decibels(_ amplitude: Double) -> Double {
    amplitude > 0.000_000_1 ? 20 * log10(amplitude) : -140
}

/// Measures one block of audio.
public struct BlockLevels: Equatable, Sendable {
    public let peak: Double
    public let rms: Double
    /// Samples pinned at full scale in a row, the sign of digital clipping.
    public let clipped: Bool

    public init(samples: UnsafeBufferPointer<Float>) {
        var largest: Float = 0
        var sum: Double = 0
        var run = 0
        var clipped = false
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > largest { largest = magnitude }
            sum += Double(sample) * Double(sample)
            if magnitude >= 0.999 {
                run += 1
                if run >= 3 { clipped = true }
            } else {
                run = 0
            }
        }
        peak = decibels(Double(largest))
        rms = decibels((sum / Double(max(1, samples.count))).squareRoot())
        self.clipped = clipped
    }
}

/// The needle's movement. Real VU meters rise and fall over about 300 ms, so the
/// reading shows loudness rather than jittering with every sample.
public struct VUBallistics: Sendable {
    public private(set) var level: Double = -60
    private let timeConstant = 0.3 / 2.2

    public init() {}

    public mutating func update(rms: Double, seconds: Double) {
        let coefficient = 1 - exp(-seconds / timeConstant)
        // Moves in linear power, as an analog needle responds to energy.
        let current = pow(10, level / 10)
        let target = pow(10, rms / 10)
        level = 10 * log10(max(current + (target - current) * coefficient, 0.000_000_01))
    }

    /// The needle position in VU, where 0 VU sits at -18 dBFS.
    public var vu: Double { level + 18 }
}

/// The loudest peak over a recent stretch, so advice isn't thrown off by a pause.
public struct RecentPeaks: Sendable {
    private var buckets: [Double]
    private var bucketClipped: [Bool]
    private var position = 0
    private var elapsedInBucket = 0.0

    public init(seconds: Int) {
        buckets = [Double](repeating: -140, count: max(1, seconds))
        bucketClipped = [Bool](repeating: false, count: max(1, seconds))
    }

    public mutating func add(peak: Double, clipped: Bool, seconds: Double) {
        buckets[position] = max(buckets[position], peak)
        bucketClipped[position] = bucketClipped[position] || clipped
        elapsedInBucket += seconds
        while elapsedInBucket >= 1 {
            elapsedInBucket -= 1
            position = (position + 1) % buckets.count
            buckets[position] = -140
            bucketClipped[position] = false
        }
    }

    public var peak: Double { buckets.max() ?? -140 }
    public var clipped: Bool { bucketClipped.contains(true) }
    public var advice: LevelAdvice { LevelAdvice.assess(peak: peak, clipped: clipped) }
}

/// Notices when a tape has probably finished.
///
/// A stopped machine usually has less noise than a playing tape, because the hiss
/// disappears, so a drop below the hiss is a strong sign. A long stretch at the hiss
/// level is a weaker one, since the tape may just have blank leader on it. This only
/// ever leads to a question. Recording never stops by itself.
public struct TapeEndDetector: Sendable {
    public var dropSeconds = 10.0
    public var quietSeconds = 60.0
    public var dropAmount = 8.0
    public var quietAmount = 6.0

    private var secondLevels: [Double] = []
    private var currentSum = 0.0
    private var currentSeconds = 0.0
    private var dismissedUntilSound = false

    public init() {}

    /// Feeds in a block's level. Returns whether the tape looks finished.
    public mutating func add(rms: Double, seconds: Double) -> Bool {
        currentSum += pow(10, rms / 10) * seconds
        currentSeconds += seconds
        guard currentSeconds >= 1 else { return false }

        secondLevels.append(10 * log10(max(currentSum / currentSeconds, 0.000_000_000_1)))
        currentSum = 0
        currentSeconds = 0
        if secondLevels.count > 600 { secondLevels.removeFirst() }
        return looksFinished
    }

    /// After "Keep recording", don't ask again until sound returns.
    public mutating func dismiss() {
        dismissedUntilSound = true
    }

    /// The tape's hiss level: a low percentile of what came before the current stretch.
    private func hissLevel(excludingLast seconds: Int) -> Double? {
        guard secondLevels.count >= seconds + 30 else { return nil }
        let earlier = secondLevels.dropLast(seconds).sorted()
        return earlier[earlier.count / 10]
    }

    private var looksFinished: Bool {
        guard let hiss = hissLevel(excludingLast: Int(dropSeconds)) else { return false }
        let recent = secondLevels.suffix(Int(dropSeconds))

        if dismissedUntilSound {
            if recent.last.map({ $0 > hiss + quietAmount }) == true {
                // Not stored as state here, because this getter can't change it.
                return false
            }
            return false
        }

        if recent.count == Int(dropSeconds), recent.allSatisfy({ $0 < hiss - dropAmount }) {
            return true
        }
        guard let quietHiss = hissLevel(excludingLast: Int(quietSeconds)) else { return false }
        let long = secondLevels.suffix(Int(quietSeconds))
        return long.count == Int(quietSeconds) && long.allSatisfy { $0 < quietHiss + quietAmount }
    }

    /// Clears the dismissal once sound comes back, so a later ending can be noticed.
    public mutating func noteSoundIfReturned() {
        guard dismissedUntilSound, let hiss = hissLevel(excludingLast: 2), let last = secondLevels.last else { return }
        if last > hiss + quietAmount + 6 { dismissedUntilSound = false }
    }
}

/// Spots a dead channel or a stereo signal that's really mono.
public struct ChannelCheck: Sendable {
    public enum Finding: Equatable, Sendable {
        case notEnoughSound
        case stereo
        case identical
        case onlyFirst
        case onlySecond
    }

    private var first = 0.0
    private var second = 0.0
    private var difference = 0.0

    public init() {}

    public mutating func add(_ a: UnsafeBufferPointer<Float>, _ b: UnsafeBufferPointer<Float>) {
        for index in 0..<min(a.count, b.count) {
            let x = Double(a[index])
            let y = Double(b[index])
            first += x * x
            second += y * y
            difference += (x - y) * (x - y)
        }
    }

    public var finding: Finding {
        let loudest = max(first, second)
        guard loudest > 0.000_01 else { return .notEnoughSound }
        // Forty decibels down is a ratio of 10,000 in power.
        if second < first / 10_000 { return .onlyFirst }
        if first < second / 10_000 { return .onlySecond }
        // Fifty decibels down: the same signal apart from noise.
        return difference < loudest / 100_000 ? .identical : .stereo
    }
}
