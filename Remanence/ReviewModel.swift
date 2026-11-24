import AppKit
import Observation
import RemanenceCore

/// The state of the review screen: what's on it, where it's zoomed, and what's selected.
@MainActor
@Observable
final class ReviewModel {
    private(set) var review: Review?
    private(set) var waveform: Waveform?
    private(set) var isHearingJoin = false
    private(set) var zoomStart: Double = 0
    private(set) var zoomSpan: Double = 90
    var selectedMarkerID: Int64?
    var snapsToQuiet = true

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var hearTask: Task<Void, Never>?
    @ObservationIgnored private var undoStack: [(name: String, action: UndoAction)] = []
    @ObservationIgnored private var redoStack: [(name: String, action: UndoAction)] = []
    @ObservationIgnored private var replay = Replay.none
    /// A deleted marker comes back with a new ID. Earlier undo steps still refer to
    /// the old one, so this keeps them pointing at the right marker.
    @ObservationIgnored private var currentIDs: [Int64: Int64] = [:]

    private typealias UndoAction = @MainActor (ReviewModel) async -> Void
    private enum Replay { case none, undoing, redoing }

    static let minimumSpan: Double = 4

    init(app: AppModel) {
        self.app = app
    }

    private var player: AudioPlayer { app.player }
    @ObservationIgnored private let scrubVoice = TapeScrubVoice()
    @ObservationIgnored private var resumeAfterScrub = false
    var duration: Double { review?.source.duration ?? 0 }
    var maximumSpan: Double { max(Self.minimumSpan, duration) }
    var selectedMarker: Marker? {
        review?.markers.first { $0.id == selectedMarkerID }
    }

    func observe(sourceID: Int64) async {
        review = nil
        waveform = nil
        selectedMarkerID = nil
        undoStack = []
        redoStack = []
        currentIDs = [:]
        guard let library = app.library else { return }
        do {
            for try await update in library.reviewUpdates(sourceID: sourceID) {
                let isFirst = review == nil
                review = update
                if isFirst, let update {
                    zoomSpan = min(90, max(Self.minimumSpan, update.source.duration))
                    showTime(player.currentTime, centered: true)
                }
                if waveform == nil, let path = update?.source.peaksPath {
                    waveform = try await library.loadWaveform(path: path)
                }
                if let selected = selectedMarkerID, update?.markers.contains(where: { $0.id == selected }) != true {
                    selectedMarkerID = nil
                }
            }
        } catch is CancellationError {
            return
        } catch {
            app.message = "This recording couldn’t be loaded for review. \(error.localizedDescription)"
        }
    }

    // MARK: Moving around

    func setZoom(span: Double, keeping anchor: Double? = nil) {
        guard duration > 0 else { return }
        let target = anchor ?? (zoomStart + zoomSpan / 2)
        let fraction = zoomSpan > 0 ? (target - zoomStart) / zoomSpan : 0.5
        zoomSpan = min(maximumSpan, max(Self.minimumSpan, span))
        moveZoom(to: target - fraction * zoomSpan)
    }

    func moveZoom(to start: Double) {
        zoomStart = max(0, min(duration - zoomSpan, start))
    }

    /// Brings a time into the zoomed view, leaving the view alone if it's already there.
    func showTime(_ time: Double, centered: Bool = false) {
        if centered || time < zoomStart || time > zoomStart + zoomSpan {
            moveZoom(to: time - zoomSpan / 2)
        }
    }

    func seek(to time: Double) {
        cancelHearing()
        let clamped = max(0, min(duration, time))
        showTime(clamped)
        Task { await player.seek(to: clamped) }
    }

    /// Moves the playhead while dragging, and plays what's under the pointer. Seeks
    /// are dropped while one's in flight, so a long tape keeps up with the pointer.
    func scrub(to time: Double) {
        cancelHearing()
        let clamped = max(0, min(duration, time))
        if !scrubVoice.isScrubbing, let url = player.currentURL {
            resumeAfterScrub = player.isPlaying
            player.pause()
            scrubVoice.begin(url)
        }
        scrubVoice.move(to: clamped)
        player.scrubLive(to: clamped)
    }

    /// Ends a drag. Playing carries on from where it let go, if it was playing.
    func endScrub() {
        guard scrubVoice.isScrubbing else { return }
        scrubVoice.end()
        if resumeAfterScrub {
            resumeAfterScrub = false
            let time = player.preciseTime
            Task {
                await player.seek(to: time)
                player.play()
            }
        }
    }

    func togglePlayback() {
        cancelHearing()
        player.togglePlayback()
    }

    // MARK: Hearing a join

    /// Plays a few seconds either side of the selected marker, the quickest way to
    /// tell if a split is in the right place.
    func hearJoin(margin: Double = 3) {
        guard let marker = selectedMarker else { return }
        cancelHearing()
        isHearingJoin = true
        let end = marker.time + margin
        showTime(marker.time)
        hearTask = Task {
            await player.seek(to: max(0, marker.time - margin))
            guard !Task.isCancelled else { return }
            player.play()
            while !Task.isCancelled, player.isPlaying, player.preciseTime < end {
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard !Task.isCancelled else { return }
            player.pause()
            isHearingJoin = false
        }
    }

    private func cancelHearing() {
        hearTask?.cancel()
        hearTask = nil
        if isHearingJoin {
            player.pause()
            isHearingJoin = false
        }
    }

    // MARK: Markers

    private func snapped(_ time: Double) -> Double {
        // Holding Option places a marker exactly, overriding the snap.
        guard snapsToQuiet, !NSEvent.modifierFlags.contains(.option), let waveform else { return time }
        return waveform.nearestQuiet(to: time) ?? time
    }

    func addMarkerAtPlayhead() {
        guard let sourceID = review?.source.id else { return }
        let time = snapped(player.preciseTime)
        Task { await addMarker(sourceID: sourceID, time: time, name: nil) }
    }

    private func addMarker(sourceID: Int64, time: Double, name: String?, replacing old: Int64? = nil) async {
        guard let library = app.library else { return }
        do {
            let id = try await library.addMarker(sourceID: sourceID, time: time, trackName: name)
            if let old { currentIDs[old] = id }
            selectedMarkerID = id
            registerUndo("Add Marker") { model in await model.deleteMarker(id: id) }
        } catch {
            app.message = error.localizedDescription
        }
    }

    func moveMarker(id: Int64, to time: Double, snapping: Bool) {
        let target = snapping ? snapped(time) : time
        Task { await moveMarker(id: id, to: target) }
    }

    private func moveMarker(id: Int64, to target: Double) async {
        let id = resolved(id)
        guard let library = app.library, let old = review?.markers.first(where: { $0.id == id })?.time,
              abs(target - old) > 0.0001 else { return }
        do {
            try await library.moveMarker(id: id, to: target)
            registerUndo("Move Marker") { model in await model.moveMarker(id: id, to: old) }
        } catch {
            NSSound.beep()
        }
    }

    func nudgeSelection(by seconds: Double) {
        if let marker = selectedMarker, let id = marker.id {
            let moved = ((marker.time + seconds) * 1000).rounded() / 1000
            let target = max(0.01, min(duration - 0.01, moved))
            moveMarker(id: id, to: target, snapping: false)
            showTime(target)
        } else {
            seek(to: player.preciseTime + seconds)
        }
    }

    func deleteSelectedMarker() {
        guard let id = selectedMarker?.id else { return }
        Task { await deleteMarker(id: id) }
    }

    private func deleteMarker(id: Int64) async {
        let id = resolved(id)
        guard let library = app.library,
              let marker = review?.markers.first(where: { $0.id == id }),
              let sourceID = review?.source.id else { return }
        let name = review?.tracks.first { $0.markerID == id }?.name
        let time = marker.time
        do {
            try await library.deleteMarker(id: id)
            if selectedMarkerID == id { selectedMarkerID = nil }
            registerUndo("Delete Marker") { model in
                await model.addMarker(sourceID: sourceID, time: time, name: name, replacing: id)
            }
        } catch {
            app.message = error.localizedDescription
        }
    }

    private func resolved(_ id: Int64) -> Int64 {
        var current = id
        while let next = currentIDs[current] { current = next }
        return current
    }

    // MARK: Undo

    private func registerUndo(_ name: String, _ action: @escaping UndoAction) {
        switch replay {
        case .undoing:
            redoStack.append((name, action))
        case .redoing:
            undoStack.append((name, action))
        case .none:
            undoStack.append((name, action))
            redoStack = []
        }
    }

    func undo() {
        guard replay == .none, let step = undoStack.popLast() else { return NSSound.beep() }
        replay = .undoing
        Task {
            await step.action(self)
            replay = .none
        }
    }

    func redo() {
        guard replay == .none, let step = redoStack.popLast() else { return NSSound.beep() }
        replay = .redoing
        Task {
            await step.action(self)
            replay = .none
        }
    }

    func selectMarker(offset: Int) {
        guard let markers = review?.markers, !markers.isEmpty else { return }
        let index: Int
        if let current = markers.firstIndex(where: { $0.id == selectedMarkerID }) {
            index = current + offset
        } else {
            let now = player.preciseTime
            index = offset > 0
                ? markers.firstIndex { $0.time > now } ?? markers.count - 1
                : markers.lastIndex { $0.time < now } ?? 0
        }
        guard markers.indices.contains(index) else { return }
        select(markers[index])
    }

    func select(_ marker: Marker) {
        selectedMarkerID = marker.id
        seek(to: marker.time)
    }

    // MARK: Trims and names

    func setTrimStart() {
        guard let source = review?.source else { return }
        let time = player.preciseTime
        Task { await applyTrim(start: time, end: source.trimEnd) }
    }

    func setTrimEnd() {
        guard let source = review?.source else { return }
        let time = player.preciseTime
        Task { await applyTrim(start: source.trimStart, end: time) }
    }

    func resetTrim() {
        Task { await applyTrim(start: 0, end: nil) }
    }

    private func applyTrim(start: Double, end: Double?) async {
        guard let source = review?.source, let id = source.id, let library = app.library else { return }
        let oldStart = source.trimStart
        let oldEnd = source.trimEnd
        do {
            try await library.setTrim(sourceID: id, start: start, end: end)
            registerUndo("Change Trim") { model in await model.applyTrim(start: oldStart, end: oldEnd) }
        } catch {
            app.message = error.localizedDescription
        }
    }

    func rename(trackID: Int64, to name: String) {
        guard let library = app.library else { return }
        Task {
            do {
                try await library.renameTrack(id: trackID, name: name)
            } catch {
                app.message = error.localizedDescription
            }
        }
    }

    // MARK: Keyboard

    /// Returns whether the key was used. Only called when no text field has focus.
    func handleKey(code: UInt16, characters: String, shift: Bool) -> Bool {
        let large = shift
        switch code {
        case 49:
            togglePlayback()
        case 123:
            nudgeSelection(by: large ? -1 : -0.1)
        case 124:
            nudgeSelection(by: large ? 1 : 0.1)
        case 51, 117:
            deleteSelectedMarker()
        case 53:
            selectedMarkerID = nil
        default:
            switch characters.lowercased() {
            case "m": addMarkerAtPlayhead()
            case "h": hearJoin()
            case "j": seek(to: player.preciseTime - (large ? 30 : 5))
            case "k": cancelHearing(); player.pause()
            case "l": player.isPlaying ? player.playFaster() : player.play()
            case ",": selectMarker(offset: -1)
            case ".": selectMarker(offset: 1)
            case "i": setTrimStart()
            case "o": setTrimEnd()
            case "=", "+": setZoom(span: zoomSpan / 1.5, keeping: player.preciseTime)
            case "-": setZoom(span: zoomSpan * 1.5, keeping: player.preciseTime)
            default: return false
            }
        }
        return true
    }
}
