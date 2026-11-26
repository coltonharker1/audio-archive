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
/// Record (the machine is usually stopped then, at the knob settings in use), and
/// says the machine has stopped once the band has sat at that floor for long enough,
/// provided the tape, while running, was clearly above it.
///
/// How long is long enough depends on where the floor came from. If listening heard
/// it for several seconds, it's taken to be the stopped machine, and a few seconds
/// there is enough. Any other floor might just be the quiet of a gap on a tape that
/// was already rolling, so every stretch at it must last a minute. Nothing heard
/// during the recording changes that.
///
/// "Running" means the seconds above the floor, plus the gaps that turned out to be
/// gaps. Quiet stretches that look like the machine stopped, such as the wait before
/// Play or an idle machine, are left out, so they don't make stopped look normal.
///
/// Each second is judged by its middle tenth, because after a reel runs out its
/// loose end can slap every few seconds as it turns.
///
/// Blank leader has no oxide and sounds like a stopped machine. That's fine: a reel
/// that has reached its leader has finished too.
///
/// This only ever leads to a question. Recording never stops by itself.
public struct MachineStopDetector: Sendable {
    /// How long the band must sit at a confirmed floor before asking.
    public var stoppedSeconds = 8
    /// How long instead when the floor isn't confirmed: it wasn't heard while
    /// listening, or the floor has since fallen well below what was.
    public var unconfirmedSeconds = 60
    /// How far above the floor still counts as stopped. A stopped machine's band
    /// moves well under a decibel from one second to the next.
    public var nearFloor = 2.5
    /// How far above the floor running tape must sit for the floor to mean stopped.
    public var runningGap = 3.0
    /// Seconds of running tape needed before judging.
    public var minimumHistory = 30
    /// How many seconds of history are kept.
    public var historyLimit = 3600
    /// How much listening before Record counts towards the floor.
    public var listeningSeconds = 30
    /// How many of those seconds must be at the floor to confirm it, so one short
    /// pause on a playing tape doesn't pass for the stopped machine.
    public var listeningConfirmSeconds = 5

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
    /// Levels in the band, in dB, of the seconds believed to be running tape, newest
    /// last, for how quiet the tape gets.
    private var history: [Double] = []
    private var floor = Double.infinity
    /// The floor as listening heard it before Record, if it heard it for long enough.
    private var heardFloor: Double?
    /// Seconds into the recording, and how many in a row have sat at the floor.
    /// Digital silence counts towards neither.
    private var second = 0
    private var quietRun = 0
    /// The current quiet run's levels, held back from `history` until the run ends and
    /// it's clearer whether the tape was running.
    private var pending: [Double] = []
    /// The current quiet run had the question raised, or sat under "Keep recording".
    private var runWasStopped = false
    /// The current quiet run began on the recording's first second.
    private var runOpensRecording = false
    /// The current quiet run lasted long enough to ask about, before there was enough
    /// history to judge it.
    private var runUnjudged = false
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
        let heard = listening.filter { $0 > -130 }
        let quietest = heard.min() ?? .infinity
        floor = quietest
        let atQuietest = heard.count { $0 <= quietest + nearFloor }
        heardFloor = atQuietest >= listeningConfirmSeconds ? quietest : nil
        second = 0
        quietRun = 0
        pending = []
        runWasStopped = false
        runOpensRecording = false
        runUnjudged = false
        listening = []
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
        // Digital silence is a missing input, not a stopped machine, so it changes
        // nothing: not the floor, a quiet run, the history or the question. A stalled
        // input is reported separately.
        guard level > -130 else { return }
        second += 1
        if level < floor - nearFloor { endRun(lowerFloor: true) }
        if level < floor { floor = level }

        let atFloor = level <= floor + nearFloor
        if atFloor {
            quietRun += 1
            if pending.isEmpty { runOpensRecording = second == 1 }
            pending.append(level)
            if pending.count > historyLimit { pending.removeFirst() }
        } else {
            endRun(lowerFloor: false)
        }

        judge(level)

        if atFloor {
            if machineStopped || dismissed { runWasStopped = true }
        } else if !machineStopped {
            history.append(level)
        }
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    /// The quiet run is over, because the level rose or a much lower floor arrived.
    /// Its seconds join the history unless it looked like the machine stopped.
    private mutating func endRun(lowerFloor: Bool) {
        // A run that opened the recording is usually the wait before Play, and one that
        // was long enough to ask about met the test for a stop. Both are guesses, made
        // only when the level then rose: if something quieter turns up instead, the run
        // was running tape.
        let looksStopped = runWasStopped || (!lowerFloor && (runOpensRecording || runUnjudged))
        if !looksStopped { history.append(contentsOf: pending) }
        pending = []
        quietRun = 0
        runWasStopped = false
        runOpensRecording = false
        runUnjudged = false
    }

    private mutating func judge(_ level: Double) {
        if dismissed {
            runningAgain = level > floor + runningGap ? runningAgain + 1 : 0
            if runningAgain >= 3 { dismissed = false }
            return
        }
        if machineStopped {
            // Cleared only by the tape clearly running again, so a bump on an idle
            // machine doesn't withdraw the question and then ask it afresh.
            runningAgain = level > floor + runningGap ? runningAgain + 1 : 0
            if runningAgain >= 3 { machineStopped = false }
            return
        }
        guard quietRun >= (floorConfirmed ? stoppedSeconds : unconfirmedSeconds) else { return }
        guard let running = runningLevel else {
            runUnjudged = true
            return
        }
        machineStopped = running >= floor + runningGap
        if machineStopped { runningAgain = 0 }
    }

    /// Whether the floor can be taken for the stopped machine: it was heard before
    /// Record, and it hasn't since fallen well below that.
    private var floorConfirmed: Bool {
        heardFloor.map { floor >= $0 - nearFloor } ?? false
    }

    /// How quiet the tape got while running: a low percentile of the history. The
    /// current quiet run isn't in it yet.
    private var runningLevel: Double? {
        guard history.count >= minimumHistory else { return nil }
        let sorted = history.sorted()
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
