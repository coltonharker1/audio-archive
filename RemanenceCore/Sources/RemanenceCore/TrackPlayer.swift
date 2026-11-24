import AVFoundation
import Observation

/// Plays one track of a master the way edit mode has it set: louder or quieter, faster
/// or slower, forwards or backwards. The master is only read.
///
/// Positions are always times in the master, whichever way it's playing, so markers,
/// transcripts and waveforms line up without converting.
@MainActor
@Observable
public final class TrackPlayer {
    public private(set) var isPlaying = false
    /// Which track is loaded, as the caller identifies it.
    public private(set) var trackKey: String?
    public private(set) var failure: String?
    /// Where playback started or was last paused, in master time. Use `position` for
    /// where it is now.
    public private(set) var anchor: Double = 0
    public private(set) var adjustments = TrackAdjustments.none
    public private(set) var start: Double = 0
    public private(set) var end: Double = 0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let varispeed = AVAudioUnitVarispeed()
    @ObservationIgnored private let gain = AVAudioUnitEQ(numberOfBands: 0)
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var feeder: ChunkFeeder?
    @ObservationIgnored private var connectedFormat: AVAudioFormat?
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// Called when a track plays through to its end.
    @ObservationIgnored public var onFinished: (@MainActor () -> Void)?

    public init() {
        engine.attach(node)
        engine.attach(varispeed)
        engine.attach(gain)
        // The output device changing, or its rate, stops the engine. Treat it as a pause.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    /// Where playback is now, in master time.
    public var position: Double {
        guard isPlaying, let rendered = renderedSeconds else { return anchor }
        let moved = adjustments.reversed ? anchor - rendered : anchor + rendered
        return min(end, max(start, moved))
    }

    /// How far into the track playback is, in listening order and at the adjusted speed.
    public var elapsed: Double {
        let master = adjustments.reversed ? end - position : position - start
        return adjustments.duration(of: max(0, master))
    }

    /// Seconds of the master played since the last start. The player node counts the
    /// master's own frames, before the speed change.
    private var renderedSeconds: Double? {
        guard let last = node.lastRenderTime, let time = node.playerTime(forNodeTime: last), time.sampleRate > 0 else {
            return nil
        }
        return max(0, Double(time.sampleTime) / time.sampleRate)
    }

    /// Loads a track ready to play from its start in listening order.
    public func load(_ url: URL, key: String, start: Double, end: Double, adjustments: TrackAdjustments) {
        stop()
        failure = nil
        do {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            self.file = file
            trackKey = key
            self.start = max(0, start)
            self.end = min(Double(file.length) / file.processingFormat.sampleRate, end)
            self.adjustments = adjustments
            anchor = adjustments.reversed ? self.end : self.start
            apply(adjustments)
        } catch {
            failure = "This recording can’t be played."
            trackKey = nil
        }
    }

    /// Changes how the loaded track sounds. Level and speed change while it plays;
    /// turning it around restarts from the same moment, going the other way.
    public func update(_ adjustments: TrackAdjustments) {
        let turned = adjustments.reversed != self.adjustments.reversed
        let wasPlaying = isPlaying
        if turned { pause() }
        self.adjustments = adjustments
        apply(adjustments)
        if turned {
            // At an edge, start from the other one rather than playing nothing.
            if adjustments.reversed, anchor <= start + 0.05 { anchor = end }
            if !adjustments.reversed, anchor >= end - 0.05 { anchor = start }
            if wasPlaying { play() }
        }
    }

    private func apply(_ adjustments: TrackAdjustments) {
        varispeed.rate = Float(adjustments.speed)
        gain.globalGain = Float(adjustments.gainDB)
    }

    public func play() {
        guard let file, !isPlaying else { return }
        let atEnd = adjustments.reversed ? anchor <= start + 0.01 : anchor >= end - 0.01
        if atEnd { anchor = adjustments.reversed ? end : start }

        let format = file.processingFormat
        if connectedFormat != format {
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(varispeed)
            engine.disconnectNodeOutput(gain)
            engine.connect(node, to: varispeed, format: format)
            engine.connect(varispeed, to: gain, format: format)
            engine.connect(gain, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            failure = "Audio output couldn’t start. \(error.localizedDescription)"
            return
        }

        let rate = format.sampleRate
        let feeder = ChunkFeeder(
            file: file,
            node: node,
            from: AVAudioFramePosition((anchor * rate).rounded()),
            to: AVAudioFramePosition(((adjustments.reversed ? start : end) * rate).rounded()),
            reversed: adjustments.reversed
        ) { [weak self] in
            Task { @MainActor in self?.finished() }
        }
        self.feeder = feeder
        feeder.begin()
        node.play()
        isPlaying = true
    }

    public func pause() {
        guard isPlaying else { return }
        anchor = position
        halt()
    }

    public func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    /// Moves to a time in the master, keeping on playing if it was.
    public func seek(to time: Double) {
        let wasPlaying = isPlaying
        halt()
        anchor = min(end, max(start, time))
        if wasPlaying { play() }
    }

    public func stop() {
        halt()
        engine.stop()
        file = nil
        trackKey = nil
        anchor = 0
        start = 0
        end = 0
    }

    private func halt() {
        feeder?.cancel()
        feeder = nil
        node.stop()
        isPlaying = false
    }

    private func finished() {
        guard isPlaying else { return }
        halt()
        anchor = adjustments.reversed ? start : end
        onFinished?()
    }
}

/// Reads a track a second at a time on its own queue and keeps a few seconds queued on
/// the player, reversing each piece when playing backwards. Reading ahead in pieces
/// keeps memory low on long tracks, and works the same in both directions.
private final class ChunkFeeder: @unchecked Sendable {
    private static let queued = 3

    private let file: AVAudioFile
    private let node: AVAudioPlayerNode
    private let target: AVAudioFramePosition
    private let reversed: Bool
    private let onFinished: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.colton.remanence.track-feeder")
    private let chunk: AVAudioFrameCount

    // Only touched on `queue`.
    private var next: AVAudioFramePosition
    private var outstanding = 0
    private var cancelled = false

    init(file: AVAudioFile, node: AVAudioPlayerNode, from: AVAudioFramePosition, to: AVAudioFramePosition,
         reversed: Bool, onFinished: @escaping @Sendable () -> Void) {
        self.file = file
        self.node = node
        self.next = from
        self.target = to
        self.reversed = reversed
        self.onFinished = onFinished
        self.chunk = AVAudioFrameCount(max(4096, file.processingFormat.sampleRate))
    }

    /// Queues the first pieces before returning, so playback starts right away.
    func begin() {
        queue.sync { fill() }
    }

    func cancel() {
        queue.sync { cancelled = true }
    }

    private var remaining: AVAudioFramePosition { reversed ? next - target : target - next }

    private func fill() {
        while !cancelled, outstanding < Self.queued, remaining > 0 {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return }
            do {
                file.framePosition = reversed ? next - AVAudioFramePosition(count) : next
                try file.read(into: buffer, frameCount: count)
            } catch {
                break
            }
            if reversed { reverseInPlace(buffer) }
            next += reversed ? -AVAudioFramePosition(count) : AVAudioFramePosition(count)
            outstanding += 1
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.played() }
            }
        }
        if !cancelled, outstanding == 0 { onFinished() }
    }

    private func played() {
        outstanding -= 1
        guard !cancelled else { return }
        fill()
    }
}
