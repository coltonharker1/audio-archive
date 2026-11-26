import Foundation

/// Notices when the tape machine has stopped: the tape has run out, and the machine
/// sits idle while Remanence goes on recording.
///
/// Silence on a tape means nothing here. Reels often have long gaps between
/// recordings. What changes when the tape stops moving is the noise. Tape passing
/// the head adds noise in the midrange: 4–8 dB above a stopped machine on the Teac
/// through the Scarlett (RA-014 side B against RA-015, November 2026). Treble hiss
/// doesn't help, because the interface's own noise is louder up there.
///
/// So this watches the 500 Hz–2 kHz band a second at a time. It keeps the quietest
/// second as the floor, starting from the last half minute of listening before
/// Record (the machine is usually stopped then, at the knob settings in use), and says the machine has stopped once the
/// band has sat at that floor for a few seconds, but only if the tape, while
/// running, was clearly above it. That condition is what keeps gaps and quiet
/// passages from counting. If the quietest second so far was running tape, then
/// everything quiet sits near the floor and nothing sits well above it, so nothing
/// is said until the tape really stops and the floor drops.
///
/// A stretch that is itself quieter than anything heard before might be the first
/// long gap on a tape where the machine was never heard stopped, so it must last a
/// minute rather than a few seconds before the question.
///
/// Each second is judged by its middle tenth, because after a reel runs out its
/// loose end can slap every few seconds as it turns.
///
/// Blank leader has no oxide and sounds like a stopped machine. That's fine: a reel
/// that has reached its leader has finished too.
///
/// This only ever leads to a question. Recording never stops by itself.
public struct MachineStopDetector: Sendable {
    /// How long the band must sit at the floor before asking.
    public var stoppedSeconds = 8
    /// How long instead when the stretch set the floor itself, so there was nothing
    /// to compare it with.
    public var unconfirmedSeconds = 60
    /// How far above the floor still counts as stopped. A stopped machine's band
    /// moves well under a decibel from one second to the next.
    public var nearFloor = 2.5
    /// How far above the floor running tape must sit for the floor to mean stopped.
    public var runningGap = 3.0
    /// Seconds of recording needed before judging.
    public var minimumHistory = 30
    /// How many seconds of history are kept.
    public var historyLimit = 3600
    /// How much listening before Record counts towards the floor.
    public var listeningSeconds = 30

    /// Whether the machine looks stopped now. It stays set until the tape runs again
    /// or it's dismissed.
    public private(set) var machineStopped = false

    private var filters: [BandFilter] = []
    private var filterRate = 0.0
    private var tenthLength = 0
    private var power = 0.0
    private var samples = 0
    private var tenths: [Double] = []
    private var isRecording = false
    /// Recent seconds while only listening, newest last.
    private var listening: [Double] = []
    /// The latest seconds' levels in the band, in dB, newest last, and whether each
    /// is already known to be the machine stopped.
    private var recent: [(level: Double, stopped: Bool)] = []
    /// Older seconds of running tape, for how quiet the tape gets. Seconds already
    /// known to be stopped are left out, so a long idle after "Keep recording"
    /// doesn't make stopped look normal.
    private var history: [Double] = []
    private var floor = Double.infinity
    /// Seconds into the recording, when the floor last dropped by more than
    /// `nearFloor`, and how many seconds in a row have sat at the floor.
    private var second = 0
    private var floorSetAt = 0
    private var quietRun = 0
    private var dismissed = false
    private var runningAgain = 0

    public init() {}

    /// Feeds in a block of audio, one buffer per channel being recorded.
    public mutating func add(_ channels: [UnsafeBufferPointer<Float>], sampleRate: Double) {
        guard let frames = channels.first?.count, frames > 0, sampleRate > 4000 else { return }
        if filterRate != sampleRate || filters.count != channels.count {
            filters = channels.map { _ in BandFilter(sampleRate: sampleRate) }
            filterRate = sampleRate
            tenthLength = Int(sampleRate / 10)
            power = 0
            samples = 0
            tenths = []
        }
        var offset = 0
        while offset < frames {
            let count = min(frames - offset, tenthLength - samples)
            for index in channels.indices {
                power += filters[index].sumOfSquares(channels[index], from: offset, count: count) / Double(channels.count)
            }
            samples += count
            offset += count
            if samples >= tenthLength { finishTenth() }
        }
    }

    /// Recording starts. What was heard while listening sets the floor to begin with.
    public mutating func beginRecording() {
        floor = listening.filter { $0 > -130 }.min() ?? .infinity
        second = 0
        floorSetAt = -1
        quietRun = 0
        listening = []
        recent = []
        history = []
        tenths = []
        power = 0
        samples = 0
        dismissed = false
        machineStopped = false
        isRecording = true
    }

    /// Recording stops, and listening carries on.
    public mutating func endRecording() {
        isRecording = false
        machineStopped = false
        listening = []
    }

    /// "Keep recording": don't ask again until the tape has run again.
    public mutating func dismiss() {
        dismissed = true
        runningAgain = 0
        machineStopped = false
    }

    private mutating func finishTenth() {
        tenths.append(10 * log10(max(power / Double(max(1, samples)), 1e-15)))
        power = 0
        samples = 0
        guard tenths.count == 10 else { return }
        // The middle tenth, so a click or a slap doesn't lift the second.
        let level = tenths.sorted()[4]
        tenths = []
        if isRecording {
            finishSecond(level)
        } else {
            listening.append(level)
            if listening.count > listeningSeconds { listening.removeFirst() }
        }
    }

    private mutating func finishSecond(_ level: Double) {
        second += 1
        recent.append((level, false))
        // Digital silence is a missing input, not a stopped machine, so it never sets
        // the floor. A stalled input is reported separately.
        if level > -130, level < floor {
            if level < floor - nearFloor {
                floorSetAt = second
                quietRun = 0
            }
            floor = level
        }
        quietRun = level <= floor + nearFloor ? quietRun + 1 : 0
        judge(level)

        if machineStopped {
            for index in recent.indices { recent[index].stopped = true }
        } else if dismissed, level <= floor + nearFloor {
            recent[recent.count - 1].stopped = true
        }
        while recent.count > stoppedSeconds + 2 {
            let oldest = recent.removeFirst()
            if !oldest.stopped { history.append(oldest.level) }
        }
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    private mutating func judge(_ level: Double) {
        if dismissed {
            runningAgain = level > floor + runningGap ? runningAgain + 1 : 0
            if runningAgain >= 3 { dismissed = false }
            return
        }
        if machineStopped {
            // Cleared only by the tape clearly running again.
            machineStopped = level <= floor + runningGap
            return
        }
        let knownBefore = floorSetAt < second - quietRun + 1
        guard quietRun >= (knownBefore ? stoppedSeconds : unconfirmedSeconds),
              let running = runningLevel else { return }
        machineStopped = running >= floor + runningGap
    }

    /// How quiet the tape got while running: a low percentile of the seconds before
    /// the current quiet stretch.
    private var runningLevel: Double? {
        let before = history.dropLast(max(0, quietRun - recent.count))
        guard before.count >= minimumHistory else { return nil }
        let sorted = before.sorted()
        return sorted[sorted.count / 5]
    }
}

/// A 500 Hz–2 kHz band: a high-pass then a low-pass, each a second-order Butterworth.
private struct BandFilter: Sendable {
    private var high: Biquad
    private var low: Biquad

    init(sampleRate: Double) {
        high = .highPass(at: 500, sampleRate: sampleRate)
        low = .lowPass(at: min(2000, sampleRate * 0.45), sampleRate: sampleRate)
    }

    mutating func sumOfSquares(_ samples: UnsafeBufferPointer<Float>, from start: Int, count: Int) -> Double {
        var sum = 0.0
        for index in start..<(start + count) {
            let value = low.run(high.run(Double(samples[index])))
            sum += value * value
        }
        return sum
    }
}

/// A second-order filter from the Audio EQ Cookbook, with Q of 1/√2.
private struct Biquad: Sendable {
    let b0, b1, b2, a1, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    static func highPass(at frequency: Double, sampleRate: Double) -> Biquad {
        let (cosine, alpha) = parts(frequency, sampleRate)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + cosine) / 2 / a0, b1: -(1 + cosine) / a0, b2: (1 + cosine) / 2 / a0,
                      a1: -2 * cosine / a0, a2: (1 - alpha) / a0)
    }

    static func lowPass(at frequency: Double, sampleRate: Double) -> Biquad {
        let (cosine, alpha) = parts(frequency, sampleRate)
        let a0 = 1 + alpha
        return Biquad(b0: (1 - cosine) / 2 / a0, b1: (1 - cosine) / a0, b2: (1 - cosine) / 2 / a0,
                      a1: -2 * cosine / a0, a2: (1 - alpha) / a0)
    }

    private static func parts(_ frequency: Double, _ sampleRate: Double) -> (cosine: Double, alpha: Double) {
        let w0 = 2 * Double.pi * frequency / sampleRate
        return (cos(w0), sin(w0) / (2 * 0.5.squareRoot()))
    }

    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}
