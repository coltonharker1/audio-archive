import AVFoundation
import Observation

/// Plays one file at a time and reports its position.
@MainActor
@Observable
public final class AudioPlayer {
    public private(set) var isPlaying = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var currentURL: URL?
    public private(set) var failure: String?

    /// Called when a file plays to its end.
    @ObservationIgnored public var onFinished: (() -> Void)?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var scrubbing = false
    @ObservationIgnored private var liveSeekInFlight = false
    @ObservationIgnored private var pendingLiveSeek: Double?

    public init() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.isPlaying = false
                self.onFinished?()
            }
        }
    }

    /// Loads a file, ready to play from the start. Returns whether it can be played.
    @discardableResult
    public func load(_ url: URL, duration: Double) async -> Bool {
        stop()
        failure = nil
        currentURL = url
        self.duration = duration

        guard FileManager.default.fileExists(atPath: url.path) else {
            failure = "This recording’s file is missing from your library."
            return false
        }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else {
            guard currentURL == url else { return false }
            failure = "This recording can’t be played."
            return false
        }
        // Another file may have been chosen while this one was being checked.
        guard currentURL == url else { return false }
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        // A seek before the item is ready is dropped without any error, so opening
        // a tape at a search result would quietly start from the beginning.
        let deadline = ContinuousClock.now + .seconds(10)
        while item.status == .unknown, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard currentURL == url else { return false }
        guard item.status == .readyToPlay else {
            failure = "This recording can’t be played."
            return false
        }
        return true
    }

    public func play() {
        guard player.currentItem != nil else { return }
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        duration = 0
        currentURL = nil
    }

    /// The exact position right now, for smooth drawing and placing markers.
    /// `currentTime` only updates a few times a second.
    public var preciseTime: Double {
        if scrubbing { return currentTime }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : currentTime
    }

    /// Plays faster each time it's called, up to four times normal speed.
    public func playFaster() {
        let next: Float = player.rate >= 2 ? 4 : 2
        player.rate = next
        isPlaying = true
    }

    /// Follows a drag on a waveform. Only the newest position is seeked to once the
    /// previous seek finishes, so requests can't pile up behind the pointer.
    public func scrubLive(to time: Double) {
        currentTime = time
        scrubbing = true
        pendingLiveSeek = time
        startNextLiveSeek()
    }

    private func startNextLiveSeek() {
        guard !liveSeekInFlight, let time = pendingLiveSeek else { return }
        pendingLiveSeek = nil
        liveSeekInFlight = true
        Task {
            await player.seek(
                to: CMTime(seconds: time, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            liveSeekInFlight = false
            if pendingLiveSeek != nil {
                startNextLiveSeek()
            } else {
                scrubbing = false
            }
        }
    }

    /// Moves the displayed position while the user drags, without seeking yet.
    public func scrub(to time: Double) {
        scrubbing = true
        currentTime = time
    }

    public func seek(to time: Double) async {
        currentTime = time
        await player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        scrubbing = false
    }
}
