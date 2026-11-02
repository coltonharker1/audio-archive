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
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
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
