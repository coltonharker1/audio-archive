import AppKit
import Observation
import RemanenceCore

/// Edit mode: every track of a tape as its own lane, each with its own level, speed
/// and direction. Nothing here touches a master. Settings are heard right away and
/// applied to the copies made when the tape is pushed.
@MainActor
@Observable
final class EditModel {
    struct Lane: Identifiable, Equatable {
        let track: PostTrack
        /// Position on the whole tape, which is how the site numbers tracks.
        let number: Int
        /// Position on its own recording, like "A3", or the plain number when the
        /// tape has a single unnamed recording.
        let label: String
        let side: String?
        let masterPath: String
        let peaksPath: String?
        /// For a piece appended to another track: that track's lane, and which piece
        /// this is after it (1 for the first appended).
        var head: String? = nil
        var pieceIndex = 0
        /// For the first piece of a track: how many pieces it has in all.
        var pieceCount = 1
        /// How long the whole track plays, with every piece.
        var totalDuration: Double = 0

        var id: String { track.id }
        var isAppended: Bool { head != nil }
        /// What plays, after any trim.
        var start: Double { track.start }
        var end: Double { track.end }
        /// The whole stretch between its markers, trimmed parts included. Edit mode
        /// draws all of it, so a trim can be widened again.
        var spanStart: Double { track.spanStart }
        var spanEnd: Double { track.spanEnd }
        var spanLength: Double { max(0.001, spanEnd - spanStart) }
    }

    private(set) var tape: Tape?
    private(set) var lanes: [Lane] = []
    private(set) var waveforms: [Int64: Waveform] = [:]
    /// True peaks measured from the master, in dB, once asked for.
    private(set) var measuredPeaks: [String: Double] = [:]
    private(set) var measuring: Set<String> = []
    let player = TrackPlayer()
    /// Plays what's under the pointer while a waveform or a trim handle is dragged.
    @ObservationIgnored private let scrubVoice = TapeScrubVoice()
    @ObservationIgnored private var scrubbingLaneID: String?
    @ObservationIgnored private var resumeAfterScrub = false

    /// The selected track, shown up close, if any, and the stretch of it in view.
    /// The view is measured in master seconds from the track's start in listening
    /// order, so a reversed track zooms the way it sounds.
    private(set) var expandedLaneID: String?
    private(set) var zoomStart: Double = 0
    private(set) var zoomSpan: Double = 0
    static let minimumZoomSpan: Double = 2

    /// Whether the screen is up. `leave()` ends that.
    @ObservationIgnored private var isOnScreen = false
    /// A selection and playhead to take up once the tracks arrive.
    @ObservationIgnored private var pendingRestore: Restore?
    /// A moment handed over from Review, to open once the tracks arrive.
    @ObservationIgnored private var pendingArrival: (tapeID: Int64, place: TrackHandoff.Place)?

    private struct Restore {
        let tapeID: Int64
        let trackID: String?
        let sourceID: Int64
        let time: Double
    }

    /// Settings being changed and not yet saved, so dragging a slider stays smooth.
    @ObservationIgnored private var unsaved: [String: TrackAdjustments] = [:]
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let app: AppModel

    init(app: AppModel) {
        self.app = app
        // A track with pieces appended plays on into the next piece.
        player.onFinished = { [weak self] in self?.playNextPiece() }
    }

    private func playNextPiece() {
        guard let key = player.trackKey, let index = lanes.firstIndex(where: { $0.id == key }),
              index + 1 < lanes.count, lanes[index + 1].isAppended else { return }
        let next = lanes[index + 1]
        guard load(next) else { return }
        // The close-up goes on with it, so its clock and playhead keep showing
        // what's heard.
        if expandedLaneID == key { expand(next) }
        player.play()
    }

    // MARK: Ordering

    /// Tracks as the site will have them, without the pieces appended to them.
    var headLanes: [Lane] { lanes.filter { !$0.isAppended } }

    /// Moves a track so it plays just before the track at `index` among the tape's
    /// tracks, or last when `index` is past the end.
    func move(_ laneID: String, before index: Int) {
        guard !isOnSite, let lane = lanes.first(where: { $0.id == laneID }) else { return }
        let heads = headLanes
        var place = index
        if let current = heads.firstIndex(where: { $0.id == laneID }) {
            if current < index { place -= 1 }
            guard place != current else { return }
        }
        move(lane, to: place)
    }

    func canMove(_ lane: Lane, by step: Int) -> Bool {
        guard !isOnSite, !lane.isAppended, let current = headLanes.firstIndex(where: { $0.id == lane.id }) else { return false }
        return headLanes.indices.contains(current + step)
    }

    func move(_ lane: Lane, by step: Int) {
        guard canMove(lane, by: step), let current = headLanes.firstIndex(where: { $0.id == lane.id }) else { return }
        move(lane, to: current + step)
    }

    private func move(_ lane: Lane, to place: Int) {
        guard let library = app.library else { return }
        let source = lane.track.sourceID, marker = lane.track.startMarkerID
        Task.detached {
            do {
                try await library.moveTrack(sourceID: source, startMarkerID: marker, to: place)
            } catch {
                await MainActor.run { [weak self] in self?.app.message = error.localizedDescription }
            }
        }
    }

    // MARK: Appending

    /// The track a lane belongs to: its own, or the one it's appended to.
    func headLane(of lane: Lane) -> Lane {
        lane.head.flatMap { head in lanes.first { $0.id == head } } ?? lane
    }

    /// The tracks a track can be appended to the end of, for choosing from a menu.
    func appendTargets(for lane: Lane) -> [Lane] {
        headLanes.filter { canAppend(lane, to: $0) }
    }

    /// Whether one track can be dropped onto another to play after it.
    func canAppend(_ moving: Lane, to target: Lane) -> Bool {
        guard !isOnSite, moving.id != target.id else { return false }
        let movingHead = headLane(of: moving).id
        let targetHead = headLane(of: target).id
        // Not onto its own track, unless it's a piece being moved to that track's end.
        if movingHead == targetHead { return false }
        return true
    }

    func append(_ moving: Lane, to target: Lane) {
        guard canAppend(moving, to: target), let library = app.library else { return }
        if player.trackKey == moving.id { player.stop() }
        let source = moving.track.sourceID, marker = moving.track.startMarkerID
        let targetSource = target.track.sourceID, targetMarker = target.track.startMarkerID
        Task.detached {
            do {
                try await library.appendTrack(sourceID: source, startMarkerID: marker, to: targetSource, targetMarkerID: targetMarker)
            } catch {
                await MainActor.run { [weak self] in self?.app.message = error.localizedDescription }
            }
        }
    }

    func detach(_ lane: Lane) {
        guard lane.isAppended, !isOnSite, let library = app.library else { return }
        let source = lane.track.sourceID, marker = lane.track.startMarkerID
        Task.detached {
            do {
                try await library.detachTrack(sourceID: source, startMarkerID: marker)
            } catch {
                await MainActor.run { [weak self] in self?.app.message = error.localizedDescription }
            }
        }
    }

    var isOnSite: Bool { tape?.pushedAt != nil }

    func observe(tapeID: Int64) async {
        isOnScreen = true
        tape = nil
        lanes = []
        measuredPeaks = [:]
        guard let library = app.library else { return }
        // A track is picked once, when they first arrive. Closing it afterward sticks.
        var needsSelection = true
        do {
            for try await post in library.postUpdates(tapeID: tapeID) {
                guard let post else { continue }
                let sources = try await library.sources(tapeID: tapeID)
                let byID = Dictionary(uniqueKeysWithValues: sources.compactMap { source in source.id.map { ($0, source) } })
                tape = post.tape
                let labelsBySide = Set(sources.map(\.side)).count > 1 || sources.contains { $0.side != nil }
                // Labels follow each piece's place on its own recording, like "B1",
                // wherever it now plays.
                let all = post.tracks.flatMap(\.pieces).sorted { a, b in
                    let pa = byID[a.sourceID]?.position ?? 0, pb = byID[b.sourceID]?.position ?? 0
                    return pa != pb ? pa < pb : a.start < b.start
                }
                var perSource: [Int64: Int] = [:]
                var labels: [String: String] = [:]
                for (index, piece) in all.enumerated() {
                    let source = byID[piece.sourceID]
                    perSource[piece.sourceID, default: 0] += 1
                    labels[piece.id] = labelsBySide
                        ? "\(source?.side ?? "\((source?.position ?? 0) + 1)")\(perSource[piece.sourceID]!)"
                        : "\(index + 1)"
                }
                lanes = post.tracks.enumerated().flatMap { index, track in
                    let pieces = track.pieces
                    return pieces.enumerated().map { pieceIndex, piece in
                        let source = byID[piece.sourceID]
                        return Lane(
                            track: piece,
                            number: index + 1,
                            label: labels[piece.id] ?? "\(index + 1)",
                            side: source?.side,
                            masterPath: source?.masterPath ?? "",
                            peaksPath: source?.peaksPath,
                            head: pieceIndex == 0 ? nil : track.id,
                            pieceIndex: pieceIndex,
                            pieceCount: pieces.count,
                            totalDuration: track.duration
                        )
                    }
                }
                if let restore = pendingRestore, !lanes.isEmpty {
                    pendingRestore = nil
                    if restore.tapeID == tapeID { apply(restore) }
                }
                // Taken up once. Later updates leave the selection and playhead be.
                if let arrival = pendingArrival, !lanes.isEmpty {
                    pendingArrival = nil
                    if arrival.tapeID == tapeID { open(arrival.place) }
                }
                if needsSelection, let first = lanes.first {
                    needsSelection = false
                    if expandedLane == nil {
                        toggleExpanded(lanes.first { $0.id == player.trackKey } ?? first)
                    }
                }
                // A split or a join changes the opened track's length, so the view refits.
                if let id = expandedLaneID {
                    if lanes.contains(where: { $0.id == id }) { setZoom(span: zoomSpan) } else { expandedLaneID = nil }
                }
                // A track that changed shape, from a split, a join or a trim, is
                // reloaded where it was, and keeps playing if it was.
                if let key = player.trackKey,
                   let lane = lanes.first(where: { $0.id == key }),
                   abs(lane.start - player.start) > 0.001 || abs(lane.end - player.end) > 0.001 {
                    let position = player.position
                    let wasPlaying = player.isPlaying
                    player.stop()
                    if load(lane) {
                        player.seek(to: min(lane.end, max(lane.start, position)))
                        if wasPlaying { player.play() }
                    }
                } else if let key = player.trackKey, !lanes.contains(where: { $0.id == key }) {
                    player.stop()
                }
                for source in sources {
                    guard let id = source.id, waveforms[id] == nil, let path = source.peaksPath else { continue }
                    waveforms[id] = try? await library.loadWaveform(path: path)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            app.message = "This tape couldn’t be opened for editing. \(error.localizedDescription)"
        }
    }

    func leave() {
        isOnScreen = false
        discardPendingPlace()
        expandedLaneID = nil
        for task in saveTasks.values { task.cancel() }
        flushSaves()
        player.stop()
    }

    // MARK: Restoring

    /// Sets what to select, and where to put the playhead, when the screen next
    /// shows this tape.
    func restore(tapeID: Int64, trackID: String?, sourceID: Int64, time: Double) {
        discardPendingPlace()
        pendingRestore = Restore(tapeID: tapeID, trackID: trackID, sourceID: sourceID, time: time)
    }

    /// Drops anything still waiting for the tracks to arrive.
    func discardPendingPlace() {
        pendingRestore = nil
        pendingArrival = nil
    }

    /// Whether this tape's tracks are on screen, with nothing still to be restored.
    func isShowingTracks(of tapeID: Int64) -> Bool {
        isOnScreen && pendingRestore == nil && pendingArrival == nil && tape?.id == tapeID && !lanes.isEmpty
    }

    /// Where the loaded track's playhead is, in master seconds of its recording.
    var loadedPosition: (sourceID: Int64, time: Double)? {
        guard let key = player.trackKey, let lane = lanes.first(where: { $0.id == key }) else { return nil }
        return (lane.track.sourceID, player.position)
    }

    /// Selects the saved track and puts the playhead back, without playing. A
    /// playhead outside the selected track is left alone. With nothing selected,
    /// it goes to whichever track holds it.
    private func apply(_ restore: Restore) {
        func holdsPlayhead(_ lane: Lane) -> Bool {
            lane.track.sourceID == restore.sourceID && restore.time >= lane.start && restore.time <= lane.end
        }
        let selected = lanes.first { $0.id == restore.trackID }
        let playing = if let selected {
            holdsPlayhead(selected) ? selected : nil
        } else {
            // On a boundary, the track starting there wins.
            lanes.filter(holdsPlayhead).max { $0.start < $1.start }
        }
        if let playing, load(playing) {
            player.seek(to: restore.time)
        }
        // Opened after the playhead is placed, so a long track zooms in around it.
        if let selected, expandedLaneID != selected.id { toggleExpanded(selected) }
    }

    // MARK: To and from Review

    /// Sets the moment of a recording to open at when the screen next shows this
    /// tape: its track is selected, with the playhead there.
    func arrive(tapeID: Int64, at place: TrackHandoff.Place) {
        discardPendingPlace()
        pendingArrival = (tapeID, place)
    }

    /// Selects the track holding a moment and puts the playhead on it, without playing.
    private func open(_ place: TrackHandoff.Place) {
        guard let arrival = TrackHandoff.arrival(sourceID: place.sourceID, time: place.time, in: lanes.map(\.track)),
              let lane = lanes.first(where: { $0.id == arrival.piece.id }) else { return }
        if load(lane) { player.seek(to: arrival.time) }
        // Opened after the playhead is placed, so a long track zooms in around it.
        if expandedLaneID != lane.id { toggleExpanded(lane) }
        follow(lane)
    }

    /// The piece a return to Review leaves from: the selected one, or the one
    /// appended to it that the playhead has moved on to. With nothing selected,
    /// it's the one holding the playhead.
    var departureLane: Lane? {
        let loaded = lanes.first { $0.id == player.trackKey }
        guard let selected = expandedLane else { return loaded }
        if let loaded, loaded.id == selected.id || loaded.head == selected.id { return loaded }
        return selected
    }

    /// The moment a return to Review goes to. A piece without the playhead is
    /// returned to where it starts playing. Read it before leaving the screen,
    /// which lets go of the selection and the playhead.
    var departure: TrackHandoff.Place? {
        guard let lane = departureLane else { return nil }
        let start = adjustments(for: lane).reversed ? lane.end : lane.start
        return TrackHandoff.place(in: lane.track, at: player.trackKey == lane.id ? player.position : start)
    }

    // MARK: Zooming

    var expandedLane: Lane? { lanes.first { $0.id == expandedLaneID } }

    /// Takes the cursor out of a name field, so keys like M and Space reach edit
    /// mode. AppKit can hand the cursor to a text field as the screen changes, so
    /// this also runs once that settles.
    func endTyping() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    func toggleExpanded(_ lane: Lane) {
        endTyping()
        if expandedLaneID == lane.id {
            expandedLaneID = nil
            return
        }
        expand(lane)
    }

    /// Selects a track and opens its close-up, leaving any typing alone.
    private func expand(_ lane: Lane) {
        expandedLaneID = lane.id
        let length = lane.spanLength
        zoomSpan = length
        zoomStart = 0
        // Open close to the playhead when it's in this track.
        if player.trackKey == lane.id, length > 60 {
            setZoom(span: 60, keeping: offset(ofMaster: player.position, in: lane))
        }
    }

    /// Where a master time falls in a track's whole stretch, counted in listening
    /// order from the first sound before any trim.
    func offset(ofMaster time: Double, in lane: Lane) -> Double {
        adjustments(for: lane).reversed ? lane.spanEnd - time : time - lane.spanStart
    }

    func master(atOffset offset: Double, in lane: Lane) -> Double {
        adjustments(for: lane).reversed ? lane.spanEnd - offset : lane.spanStart + offset
    }

    func setZoom(span: Double, keeping anchor: Double? = nil) {
        guard let lane = expandedLane else { return }
        let length = lane.spanLength
        let target = anchor ?? (zoomStart + zoomSpan / 2)
        let fraction = zoomSpan > 0 ? (target - zoomStart) / zoomSpan : 0.5
        zoomSpan = min(length, max(min(length, Self.minimumZoomSpan), span))
        moveZoom(to: target - fraction * zoomSpan)
    }

    func moveZoom(to start: Double) {
        guard let lane = expandedLane else { return }
        zoomStart = max(0, min(lane.spanLength - zoomSpan, start))
    }

    /// Zooms around the playhead when it's in view, or the middle otherwise.
    func zoom(by factor: Double) {
        guard let lane = expandedLane else { return }
        var anchor: Double?
        if player.trackKey == lane.id {
            let playhead = offset(ofMaster: player.position, in: lane)
            if playhead >= zoomStart, playhead <= zoomStart + zoomSpan { anchor = playhead }
        }
        setZoom(span: zoomSpan / factor, keeping: anchor)
    }

    /// Keeps the playhead in view as it plays.
    func follow(_ lane: Lane) {
        guard expandedLaneID == lane.id, player.trackKey == lane.id, zoomSpan < lane.spanLength else { return }
        let playhead = offset(ofMaster: player.position, in: lane)
        if playhead < zoomStart || playhead > zoomStart + zoomSpan { moveZoom(to: playhead - zoomSpan * 0.1) }
    }

    /// Sideways scrolling in the zoomed track.
    func scroll(by points: Double) -> Bool {
        guard expandedLane != nil else { return false }
        moveZoom(to: zoomStart - points * zoomSpan / 800)
        return true
    }

    /// Seeks to a point in a track, counted in master seconds in listening order.
    /// A point in a trimmed part goes to the nearest edge of what plays.
    func seek(_ lane: Lane, toOffset offset: Double) {
        endTyping()
        guard load(lane) else { return }
        player.seek(to: min(lane.end, max(lane.start, master(atOffset: offset, in: lane))))
    }

    // MARK: Scrubbing

    /// Plays the audio under the pointer as it's dragged, even while paused. Call it
    /// for each move of a drag; the first starts the scrub. `offset` is in master
    /// seconds in listening order, across the whole track, trimmed parts included,
    /// so a trim can be placed by ear. `movesPlayhead` is false for trim handles.
    func scrub(_ lane: Lane, toOffset offset: Double, movesPlayhead: Bool = true) {
        let time = master(atOffset: min(lane.spanLength, max(0, offset)), in: lane)
        if scrubbingLaneID != lane.id {
            endTyping()
            if scrubbingLaneID != nil { scrubVoice.end() }
            guard let library = app.library, let url = try? library.url(forLibraryPath: lane.masterPath) else { return }
            app.player.pause()
            resumeAfterScrub = player.trackKey == lane.id && player.isPlaying
            if player.isPlaying { player.pause() }
            scrubbingLaneID = lane.id
            scrubVoice.begin(url, adjustments: adjustments(for: lane))
        }
        scrubVoice.move(to: time)
        if movesPlayhead, load(lane) {
            player.seek(to: min(lane.end, max(lane.start, time)))
        }
    }

    /// Ends a scrub. The playhead stays where the pointer let go, and playing
    /// carries on from there if it was playing before.
    func endScrub(_ lane: Lane, atOffset offset: Double?) {
        let wasScrubbing = scrubbingLaneID == lane.id
        scrubVoice.end()
        scrubbingLaneID = nil
        if let offset {
            seek(lane, toOffset: offset)
        }
        if wasScrubbing, resumeAfterScrub, player.trackKey == lane.id {
            player.play()
        }
        resumeAfterScrub = false
    }

    // MARK: Settings

    func adjustments(for lane: Lane) -> TrackAdjustments {
        unsaved[lane.id] ?? lane.track.adjustments
    }

    func set(_ adjustments: TrackAdjustments, for lane: Lane) {
        guard !isOnSite else { return }
        unsaved[lane.id] = adjustments
        if player.trackKey == lane.id { player.update(adjustments) }
        saveTasks[lane.id]?.cancel()
        saveTasks[lane.id] = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save(lane)
        }
    }

    private func flushSaves() {
        for lane in lanes where unsaved[lane.id] != nil { save(lane) }
    }

    private func save(_ lane: Lane) {
        guard let library = app.library, let adjustments = unsaved[lane.id] else { return }
        let sourceID = lane.track.sourceID
        let markerID = lane.track.startMarkerID
        // GRDB refuses writes from cancelled tasks, so the write runs on its own.
        Task.detached {
            do {
                try await library.setAdjustments(sourceID: sourceID, startMarkerID: markerID, adjustments)
                await MainActor.run { [weak self] in
                    if self?.unsaved[lane.id] == adjustments { self?.unsaved[lane.id] = nil }
                }
            } catch {
                await MainActor.run { [weak self] in self?.app.message = error.localizedDescription }
            }
        }
    }

    func rename(_ lane: Lane, to name: String) {
        guard let library = app.library, name != (lane.track.name ?? "") else { return }
        let sourceID = lane.track.sourceID
        let markerID = lane.track.startMarkerID
        Task.detached {
            try? await library.saveTrack(sourceID: sourceID, startMarkerID: markerID, name: name)
        }
    }

    /// The loudest moment of a track as it is now, before its level change. Uses the
    /// exact measurement once there is one, and the waveform's estimate until then.
    func loudestPeak(of lane: Lane) -> (decibels: Double, exact: Bool)? {
        if let measured = measuredPeaks[lane.id] { return (measured, true) }
        guard let estimate = waveforms[lane.track.sourceID]?.loudestPeak(from: lane.start, to: lane.end) else { return nil }
        return (estimate, false)
    }

    /// Sets the level so the loudest moment sits just under full scale.
    func fitLevel(_ lane: Lane) {
        guard let library = app.library, !measuring.contains(lane.id) else { return }
        measuring.insert(lane.id)
        Task {
            defer { measuring.remove(lane.id) }
            do {
                let url = try library.url(forLibraryPath: lane.masterPath)
                let start = lane.start
                let end = lane.end
                let peak = try await Task.detached(priority: .userInitiated) {
                    try measurePeak(of: url, from: start, to: end)
                }.value
                measuredPeaks[lane.id] = peak
                var adjusted = adjustments(for: lane)
                adjusted = TrackAdjustments(gainDB: -1 - peak, speed: adjusted.speed, reversed: adjusted.reversed)
                set(adjusted, for: lane)
            } catch {
                app.message = "Couldn’t measure this track. \(error.localizedDescription)"
            }
        }
    }

    // MARK: Playing

    private func load(_ lane: Lane) -> Bool {
        if player.trackKey == lane.id { return true }
        guard let library = app.library, let url = try? library.url(forLibraryPath: lane.masterPath) else { return false }
        app.player.pause()
        player.load(url, key: lane.id, start: lane.start, end: lane.end, adjustments: adjustments(for: lane))
        if let failure = player.failure { app.message = failure }
        return player.trackKey == lane.id
    }

    func togglePlayback(_ lane: Lane) {
        guard load(lane) else { return }
        player.togglePlayback()
        if let failure = player.failure { app.message = failure }
    }

    func toggleCurrent() {
        if let key = player.trackKey, let lane = lanes.first(where: { $0.id == key }) {
            togglePlayback(lane)
        } else if let first = lanes.first {
            togglePlayback(first)
        }
    }

    /// Moves by a number of listening seconds in the loaded track.
    func skip(by seconds: Double) {
        guard let key = player.trackKey, let lane = lanes.first(where: { $0.id == key }) else { return }
        let settings = adjustments(for: lane)
        let master = seconds * settings.speed * (settings.reversed ? -1 : 1)
        player.seek(to: player.position + master)
    }

    // MARK: Splitting and joining

    /// Whether the playhead is far enough inside a track to split it there.
    func canSplit(_ lane: Lane) -> Bool {
        guard !isOnSite, player.trackKey == lane.id else { return false }
        let time = player.position
        return time > lane.start + 0.5 && time < lane.end - 0.5
    }

    /// Splits a track at the playhead, at the nearest quiet moment unless Option is
    /// held. The new track starts with the same settings, since speed and level only
    /// change between recordings.
    func split(_ lane: Lane) {
        guard canSplit(lane), let library = app.library else { return }
        var time = player.position
        // Zoomed in, the playhead was placed by eye, so it only moves a little.
        let reach = expandedLaneID == lane.id ? min(3, zoomSpan / 50) : 3
        if !NSEvent.modifierFlags.contains(.option),
           let quiet = waveforms[lane.track.sourceID]?.nearestQuiet(to: time, within: reach),
           quiet > lane.start + 0.5, quiet < lane.end - 0.5 {
            time = quiet
        }
        let sourceID = lane.track.sourceID
        let settings = adjustments(for: lane)
        player.pause()
        Task.detached {
            do {
                let marker = try await library.addMarker(sourceID: sourceID, time: time)
                if !settings.isNeutral {
                    try await library.setAdjustments(sourceID: sourceID, startMarkerID: marker, settings)
                }
            } catch {
                await MainActor.run { [weak self] in self?.app.message = error.localizedDescription }
            }
        }
    }

    /// Whether a track can be joined onto the one before it on the same recording.
    func canJoin(_ lane: Lane) -> Bool {
        !isOnSite && lane.track.startMarkerID != nil
    }

    func joinWithPrevious(_ lane: Lane) {
        guard canJoin(lane), let library = app.library, let marker = lane.track.startMarkerID else { return }
        if player.trackKey == lane.id { player.stop() }
        Task.detached {
            do {
                try await library.deleteMarker(id: marker)
            } catch {
                await MainActor.run { [weak self] in self?.app.message = error.localizedDescription }
            }
        }
    }

    // MARK: Trimming

    /// How much is trimmed from the start and end of a track as it's heard. On a
    /// reversed track the start you hear is the end of the recording.
    func heardCuts(_ lane: Lane) -> (start: Double, end: Double) {
        adjustments(for: lane).reversed
            ? (lane.track.cutEnd, lane.track.cutStart)
            : (lane.track.cutStart, lane.track.cutEnd)
    }

    /// The most that can be trimmed from one end, given the other.
    func maximumCut(_ lane: Lane, besides other: Double) -> Double {
        max(0, lane.spanLength - other - Library.minimumKeptLength)
    }

    /// Trims a track by dragging its edges. Nothing is cut from the master.
    func setHeardCuts(_ lane: Lane, start: Double, end: Double) {
        let start = min(max(0, start), maximumCut(lane, besides: max(0, end)))
        let end = min(max(0, end), maximumCut(lane, besides: start))
        let current = heardCuts(lane)
        guard abs(start - current.start) > 0.0005 || abs(end - current.end) > 0.0005 else { return }
        if adjustments(for: lane).reversed {
            setCuts(lane, start: end, end: start)
        } else {
            setCuts(lane, start: start, end: end)
        }
    }

    func resetTrim(_ lane: Lane) {
        setCuts(lane, start: 0, end: 0)
    }

    private func setCuts(_ lane: Lane, start: Double, end: Double) {
        guard !isOnSite, let library = app.library else { return }
        let source = lane.track.sourceID, marker = lane.track.startMarkerID
        Task.detached {
            do {
                try await library.setCuts(sourceID: source, startMarkerID: marker, start: max(0, start), end: max(0, end))
            } catch {
                await MainActor.run { [weak self] in self?.app.message = error.localizedDescription }
            }
        }
    }

    // MARK: Keyboard

    func handleKey(code: UInt16, characters: String, shift: Bool) -> Bool {
        switch code {
        case 49:
            toggleCurrent()
        case 123:
            skip(by: shift ? -30 : -5)
        case 124:
            skip(by: shift ? 30 : 5)
        case _ where expandedLane != nil && ["=", "+"].contains(characters):
            zoom(by: 1.5)
        case _ where expandedLane != nil && characters == "-":
            zoom(by: 1 / 1.5)
        case 53 where expandedLane != nil:
            expandedLaneID = nil
        default:
            guard characters.lowercased() == "m",
                  let key = player.trackKey, let lane = lanes.first(where: { $0.id == key }) else { return false }
            if canSplit(lane) { split(lane) } else { NSSound.beep() }
        }
        return true
    }
}
