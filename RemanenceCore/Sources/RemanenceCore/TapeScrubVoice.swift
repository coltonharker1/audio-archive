import AVFoundation
import os

/// Makes a scrub sound like rocking a reel by hand. A play head follows the pointer
/// with a little weight, so dragging slowly plays slow and low, dragging fast plays
/// fast and high, dragging back plays backwards, and letting the pointer rest winds
/// the sound down to silence. Like a real tape head, it gets quieter as it slows.
///
/// Sound is made a few milliseconds at a time on its own queue, read straight from
/// the file, which is only read.
@MainActor
public final class TapeScrubVoice {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let gain = AVAudioUnitEQ(numberOfBands: 0)
    private var connected: AVAudioFormat?
    private var url: URL?
    private var file: AVAudioFile?
    private var generator: TapeGenerator?
    private var generation = 0
    public private(set) var isScrubbing = false

    public init() {
        engine.attach(node)
        engine.attach(varispeed)
        engine.attach(gain)
    }

    /// Gets ready to scrub a file, sounding the way it will play.
    public func begin(_ url: URL, adjustments: TrackAdjustments = .none) {
        generator?.stop()
        generator = nil
        node.stop()
        generation += 1
        if self.url != url {
            file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            self.url = file == nil ? nil : url
        }
        // A file of its own for the generator's queue, so reads never cross threads.
        guard let url = self.url, let format = file?.processingFormat,
              let own = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else { return }
        varispeed.rate = Float(adjustments.speed)
        gain.globalGain = Float(adjustments.gainDB)
        if connected != format {
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(varispeed)
            engine.disconnectNodeOutput(gain)
            engine.connect(node, to: varispeed, format: format)
            engine.connect(varispeed, to: gain, format: format)
            engine.connect(gain, to: engine.mainMixerNode, format: format)
            connected = format
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return
        }
        let generator = TapeGenerator(file: own, node: node)
        self.generator = generator
        node.play()
        generator.start()
        isScrubbing = true
    }

    /// Follows the pointer to a time in the master.
    public func move(to time: Double) {
        guard isScrubbing else { return }
        generator?.follow(time)
    }

    /// Lets go. The reel winds down where the pointer left it, then stops.
    public func end() {
        guard isScrubbing else { return }
        isScrubbing = false
        let generation = generation
        let generator = generator
        DispatchQueue.main.asyncAfter(deadline: .now() + TapeGenerator.windDown) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                generator?.stop()
                self.generator = nil
                self.node.stop()
                self.engine.pause()
            }
        }
    }
}

/// Moves a play head after a target and turns its path into sound, one short block
/// at a time, keeping a few blocks queued on the player.
final class TapeGenerator: @unchecked Sendable {
    /// How long one block plays, and how many wait in line. Together they set how
    /// far the sound trails the pointer.
    static let blockLength = 0.012
    static let queued = 3
    /// How long the reel takes to settle after the pointer stops, and the fastest it
    /// may spin, as a multiple of normal speed.
    static let settle = 0.045
    static let topSpeed = 6.0
    /// Below this speed the head is treated as still, and nothing is heard.
    static let restSpeed = 0.02
    /// Further than this, the head jumps instead of spinning there.
    static let jumpDistance = 4.0
    static let windDown = 0.15

    private let file: AVAudioFile
    private let node: AVAudioPlayerNode
    private let queue = DispatchQueue(label: "com.colton.remanence.tape-scrub", qos: .userInteractive)
    private let rate: Double
    private let channels: Int
    private let blockFrames: AVAudioFrameCount
    private let lock = OSAllocatedUnfairLock(initialState: Target())

    private struct Target {
        var time: Double?
        var stopped = false
    }

    // Only touched on `queue`, in frames of the file.
    private(set) var head: Double?
    private(set) var velocity: Double = 0
    private var outstanding = 0
    private var level: Float = 0
    private var scratch: AVAudioPCMBuffer?

    init(file: AVAudioFile, node: AVAudioPlayerNode) {
        self.file = file
        self.node = node
        rate = file.processingFormat.sampleRate
        channels = Int(file.processingFormat.channelCount)
        blockFrames = AVAudioFrameCount(max(64, (Self.blockLength * rate).rounded()))
    }

    func start() {
        queue.async { self.fill() }
    }

    func follow(_ time: Double) {
        lock.withLock { $0.time = time }
    }

    func stop() {
        lock.withLock { $0.stopped = true }
    }

    private func fill() {
        while outstanding < Self.queued {
            let (target, stopped) = lock.withLock { ($0.time, $0.stopped) }
            guard !stopped else { return }
            guard let buffer = block(towards: target.map { $0 * rate }) else { return }
            outstanding += 1
            node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.outstanding -= 1
                    self.fill()
                }
            }
        }
    }

    /// One block of sound, moving the head towards the target as a weighted reel
    /// would: a critically damped spring, so it arrives without overshooting.
    func block(towards target: Double?) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames),
              let out = output.floatChannelData else { return nil }
        output.frameLength = blockFrames
        let frames = Int(blockFrames)
        for channel in 0..<channels { out[channel].update(repeating: 0, count: frames) }

        guard let target else { return output }
        if head == nil || abs(target - head!) > Self.jumpDistance * rate {
            head = target
            velocity = 0
        }
        var position = head!
        let omega = 1 / Self.settle
        let dt = 1 / rate
        let top = Self.topSpeed

        // Work out the head's path first, so the file is read once for the block.
        var path = [Double](repeating: 0, count: frames)
        var speeds = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            // The spring works in seconds. `velocity` is the head's speed as a
            // multiple of normal: 1 plays at normal speed, -1 backwards.
            let error = (target - position) / rate
            let acceleration = omega * omega * error - 2 * omega * velocity
            velocity = max(-top, min(top, velocity + acceleration * dt))
            position += velocity
            position = max(0, min(Double(file.length - 1), position))
            path[index] = position
            speeds[index] = Float(abs(velocity))
        }
        head = position

        let lowest = Int((path.min() ?? 0).rounded(.down)) - 1
        let highest = Int((path.max() ?? 0).rounded(.up)) + 2
        let from = max(0, lowest)
        let to = min(Int(file.length), highest + 1)
        let count = to - from
        guard count > 1, (speeds.max() ?? 0) > Float(Self.restSpeed) || level > 0.001 else {
            level = 0
            return output
        }
        if scratch == nil || scratch!.frameCapacity < AVAudioFrameCount(count) {
            scratch = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))
        }
        guard let scratch, let source = scratch.floatChannelData else { return output }
        do {
            file.framePosition = AVAudioFramePosition(from)
            try file.read(into: scratch, frameCount: AVAudioFrameCount(count))
        } catch {
            return output
        }
        let available = Int(scratch.frameLength)
        guard available > 1 else { return output }

        for index in 0..<frames {
            // Louder as it speeds up, up to normal level at normal speed, eased so a
            // start or stop never clicks.
            let wanted = min(1, max(0, (speeds[index] - Float(Self.restSpeed)) / Float(1 - Self.restSpeed)))
            level += (wanted - level) * 0.01
            let place = path[index] - Double(from)
            let whole = Int(place.rounded(.down))
            let fraction = Float(place - Double(whole))
            for channel in 0..<channels {
                let samples = source[channel]
                func sample(_ at: Int) -> Float { samples[max(0, min(available - 1, at))] }
                // Cubic interpolation between the samples around the head.
                let a = sample(whole - 1), b = sample(whole), c = sample(whole + 1), d = sample(whole + 2)
                let value = b + 0.5 * fraction * (c - a + fraction * (2 * a - 5 * b + 4 * c - d + fraction * (3 * (b - c) + d - a)))
                out[channel][index] = value * level
            }
        }
        return output
    }
}
