import RemanenceCore
import SwiftUI

/// A tape's tracks in site order, a close-up of the selected one, and its level,
/// speed, direction and trims beside them.
struct EditView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingAppend: PendingAppend?

    let tape: ShelfTape
    @Binding var showsInspector: Bool
    let size: LayoutSize

    private var edit: EditModel { model.editModel }

    var body: some View {
        Group {
            if edit.lanes.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening the tracks…")
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: size == .regular ? 28 : 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        trackList
                        HairlineRule()
                        CloseUpSection(size: size)
                        // The inspector says this too, so it's only here without it.
                        if !showsInspector {
                            SettingsNote(locked: edit.isOnSite)
                                .lineLimit(2)
                                .padding(.bottom, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    if showsInspector {
                        Inspector(size: size) { moving, target in
                            pendingAppend = PendingAppend(moving: moving, target: target)
                        }
                        .frame(width: size.rightColumn)
                    }
                }
                .padding(.horizontal, 28)
            }
        }
        .background(Theme.paper)
        .task(id: tape.id) { await edit.observe(tapeID: tape.id) }
        .onDisappear { edit.leave() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Track Settings", systemImage: "sidebar.trailing")
                }
                .help(showsInspector ? "Hide track settings" : "Show track settings")
            }
        }
        .confirmationDialog(
            pendingAppend.map { "Append \($0.moving.label) to the end of \($0.target.label)?" } ?? "",
            isPresented: Binding(get: { pendingAppend != nil }, set: { if !$0 { pendingAppend = nil } }),
            titleVisibility: .visible,
            presenting: pendingAppend
        ) { pending in
            Button("Append") { edit.append(pending.moving, to: pending.target) }
        } message: { pending in
            Text(appendMessage(pending))
        }
    }

    /// The heading and a row for each track. This is the part that scrolls.
    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text("Tracks in site order")
                    .font(Theme.serif(size.sectionTitle))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text(edit.headLanes.count == 1 ? "1 track" : "\(edit.headLanes.count) tracks")
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
            }
            .padding(.top, 10)
            .padding(.bottom, 2)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(edit.lanes) { lane in
                        if !lane.isAppended {
                            DropGap(locked: edit.isOnSite) { moving in
                                edit.move(moving, before: lane.number - 1)
                            }
                        }
                        LaneRow(lane: lane, size: size) { moving in
                            guard let moving = edit.lanes.first(where: { $0.id == moving }),
                                  edit.canAppend(moving, to: lane) else { return false }
                            pendingAppend = PendingAppend(moving: moving, target: edit.headLane(of: lane))
                            return true
                        }
                        .padding(.leading, lane.isAppended ? 28 : 0)
                        .padding(.top, lane.isAppended ? 4 : 0)
                    }
                    DropGap(locked: edit.isOnSite) { moving in
                        edit.move(moving, before: edit.headLanes.count)
                    }
                }
            }
            .frame(minHeight: 60, maxHeight: .infinity)
        }
    }

    private func appendMessage(_ pending: PendingAppend) -> String {
        let name = { (lane: EditModel.Lane) in lane.track.name.flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? lane.label }
        var text = "\(name(pending.moving)) will play straight after \(name(pending.target)), as one track on the site."
        if pending.moving.pieceCount > 1, !pending.moving.isAppended {
            text += " The pieces already appended to it come too."
        }
        text += " Each piece keeps its own level, speed and direction, and nothing is cut from your recordings. You can detach it again before pushing."
        return text
    }
}

private enum EditColors {
    static let clipped = Color(red: 0.604, green: 0.184, blue: 0.102)
}

/// What a track is called where it needs a name: its own, or its place.
private func displayName(_ lane: EditModel.Lane) -> String {
    if let name = lane.track.name, !name.isEmpty { return name }
    return lane.isAppended ? "Piece \(lane.label)" : "Track \(lane.number)"
}

/// That the masters are safe, or why the settings can't be changed.
private struct SettingsNote: View {
    let locked: Bool

    var body: some View {
        Text(locked
             ? "This tape is on the site. Its audio there can’t be replaced yet, so these settings are locked."
             : "Level, speed and direction are heard here and applied when you push. Your masters never change.")
            .font(.system(size: 12))
            .foregroundStyle(locked ? Theme.attention : Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The rule between two tracks. Dropping a track here moves it to this place.
private struct DropGap: View {
    @State private var isTargeted = false

    let locked: Bool
    let onDrop: (String) -> Void

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 9)
            .frame(maxWidth: .infinity)
            .overlay {
                HairlineRule()
                if isTargeted {
                    Capsule().fill(Theme.accent).frame(height: 3)
                }
            }
            .contentShape(.rect)
            .dropDestination(for: String.self) { items, _ in
                guard !locked, let first = items.first else { return false }
                onDrop(first)
                return true
            } isTargeted: { isTargeted = $0 && !locked }
            .accessibilityHidden(true)
    }
}

/// A track dropped onto another, or picked from the menu, waiting for confirmation.
private struct PendingAppend {
    let moving: EditModel.Lane
    let target: EditModel.Lane
}

/// A track in the list: its place, name and length over its waveform. A click selects
/// it, and a double-click on its name renames it.
private struct LaneRow: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var isDropTarget = false
    @State private var isEditingName = false
    @FocusState private var isNaming: Bool

    let lane: EditModel.Lane
    let size: LayoutSize
    /// Called with the dragged lane's id when a track is dropped here.
    var onDrop: (String) -> Bool = { _ in false }

    private var edit: EditModel { model.editModel }
    private var settings: TrackAdjustments { edit.adjustments(for: lane) }
    private var isSelected: Bool { edit.expandedLaneID == lane.id }
    private var locked: Bool { edit.isOnSite }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if lane.isAppended {
                    Label("Then, as part of the same track", systemImage: "arrow.turn.down.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                titleRow
                // On its own line, so the name keeps its room when the row is narrow.
                if lane.pieceCount > 1, !lane.isAppended {
                    Text("\(lane.pieceCount) pieces · \(TimeLabel.clock(lane.totalDuration))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .help("How long the whole track plays, with the pieces appended to it")
                }
            }
            .padding(.top, 7)
            .padding(.bottom, 5)
            .contentShape(.rect)
            .onTapGesture { edit.toggleExpanded(lane) }

            // The waveform keeps its own clicks, which place the playhead and select
            // the track without closing it.
            LaneWaveform(lane: lane, settings: settings)
                .frame(height: isSelected ? 48 : 30)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, size == .regular ? 14 : 8)
        .background(isSelected ? Theme.inset : .clear)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first else { return false }
            return onDrop(first)
        } isTargeted: { isDropTarget = $0 && !locked }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onAppear { name = lane.track.name ?? "" }
        .onChange(of: lane.track.name) { _, updated in
            if !isNaming { name = updated ?? "" }
        }
        .onChange(of: isNaming) { _, naming in
            if !naming { finishNaming() }
        }
        // Choosing another tab can take the field away before it loses focus.
        .onDisappear(perform: finishNaming)
    }

    private func finishNaming() {
        guard isEditingName else { return }
        isEditingName = false
        edit.rename(lane, to: name)
    }

    private var titleRow: some View {
        HStack(spacing: size == .regular ? 10 : 7) {
            if !locked {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 14, height: 22)
                    .contentShape(.rect)
                    .draggable(lane.id) {
                        Text(lane.track.name.flatMap { $0.isEmpty ? nil : $0 } ?? lane.label)
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.inset, in: .rect(cornerRadius: 6))
                    }
                    .help("Drag between tracks to move it, or onto a track to append it to that track's end")
                    .accessibilityLabel("Drag \(lane.label) onto another track")
            }
            if !lane.isAppended {
                Text(trackNumberText(lane.number))
                    .font(Theme.mono())
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                    .help("Its place on the site")
            }
            // Where it is on its recording, when that says more than its place on the
            // site. A sided track's "Side A" further along already says it.
            if lane.isAppended || (lane.side == nil && lane.label != "\(lane.number)") {
                Text(lane.label)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                    .help("Where it is on its recording")
            }

            nameField

            if lane.track.isCut {
                Image(systemName: "scissors")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .help(trimHelp)
                    .accessibilityLabel("Trimmed")
            }
            // The side, and how long this row plays.
            HStack(spacing: 5) {
                if let side = lane.side {
                    Text("Side \(side)")
                        .lineLimit(1)
                    Text("/")
                        .fixedSize()
                }
                Text(TimeLabel.clock(settings.duration(of: lane.end - lane.start)))
                    .fixedSize()
            }
            .font(Theme.mono())
            .foregroundStyle(Theme.ink)
            .accessibilityElement(children: .combine)
        }
    }

    /// What the trim leaves out, as the track is heard.
    private var trimHelp: String {
        let heardStart = settings.reversed ? lane.track.cutEnd : lane.track.cutStart
        let heardEnd = settings.reversed ? lane.track.cutStart : lane.track.cutEnd
        let parts = [
            heardStart > 0 ? "\(TimeLabel.clock(heardStart / settings.speed)) left out at the start" : nil,
            heardEnd > 0 ? "\(TimeLabel.clock(heardEnd / settings.speed)) left out at the end" : nil,
        ].compactMap(\.self)
        return parts.joined(separator: ", ") + ". Drag the edges of the waveform to change it. The recording is untouched."
    }

    /// The track's name, which becomes editable on a double-click, so typing a key
    /// meant for edit mode never lands in it.
    @ViewBuilder private var nameField: some View {
        let placeholder = lane.isAppended ? "Piece name, for you only" : "Track \(lane.number)"
        if isEditingName {
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .focused($isNaming)
                .onSubmit {
                    isEditingName = false
                    edit.rename(lane, to: name)
                    edit.endTyping()
                }
                .onExitCommand {
                    isEditingName = false
                    name = lane.track.name ?? ""
                    edit.endTyping()
                }
                .onAppear { DispatchQueue.main.async { isNaming = true } }
                .accessibilityLabel("Name of \(lane.label)")
        } else {
            let shown = name.isEmpty ? placeholder : name
            Text(shown)
                .font(Theme.serif(size.rowName))
                .foregroundStyle(name.isEmpty ? Theme.muted : Theme.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                // A double-click renames without also selecting or closing the track.
                .gesture(
                    TapGesture(count: 2).onEnded { rename() }
                        .exclusively(before: TapGesture().onEnded { edit.toggleExpanded(lane) })
                )
                .help("\(shown). Double-click to rename.")
                .accessibilityLabel("Name of \(lane.label): \(shown)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { edit.toggleExpanded(lane) }
                .accessibilityAction(named: "Rename") { rename() }
        }
    }

    private func rename() {
        name = lane.track.name ?? ""
        isEditingName = true
    }
}

/// A track's waveform drawn as it will sound: raised or lowered, and turned around
/// when reversed. Click or drag to move the playhead.
private struct LaneWaveform: View {
    @Environment(AppModel.self) private var model

    let lane: EditModel.Lane
    let settings: TrackAdjustments

    var body: some View {
        let edit = model.editModel
        let player = edit.player
        let loaded = player.trackKey == lane.id
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    guard let waveform = edit.waveforms[lane.track.sourceID] else { return }
                    let columns = max(1, Int(size.width / 2))
                    var levels = waveform.levels(from: lane.spanStart, to: lane.spanEnd, columns: columns, gainDB: settings.gainDB)
                    if settings.reversed { levels.reverse() }
                    let width = size.width / CGFloat(max(1, levels.count))
                    for (index, level) in levels.enumerated() {
                        let height = max(1, CGFloat(level) * size.height)
                        let rect = CGRect(x: CGFloat(index) * width, y: (size.height - height) / 2,
                                          width: max(0.5, width - 0.5), height: height)
                        context.fill(Path(rect), with: .color(level >= 0.999 ? EditColors.clipped : Theme.waveform))
                    }
                }
                // On the selected track, the stretch the close-up shows.
                if edit.expandedLaneID == lane.id, edit.zoomSpan < lane.spanLength - 0.001 {
                    Rectangle()
                        .fill(Theme.accent.opacity(0.1))
                        .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1))
                        .frame(width: max(4, geometry.size.width * edit.zoomSpan / lane.spanLength), height: geometry.size.height)
                        .offset(x: geometry.size.width * edit.zoomStart / lane.spanLength)
                        .allowsHitTesting(false)
                }
                if loaded {
                    // Reading the anchor redraws after a seek while paused.
                    let _ = player.anchor
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying)) { _ in
                        let fraction = edit.offset(ofMaster: player.position, in: lane) / lane.spanLength
                        Rectangle()
                            .fill(Theme.needle)
                            .frame(width: 2, height: geometry.size.height)
                            .offset(x: max(0, min(1, fraction)) * (geometry.size.width - 2))
                    }
                    .allowsHitTesting(false)
                }
                TrimOverlay(lane: lane, windowStart: 0, windowSpan: lane.spanLength)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // A click only places the playhead; moving makes it heard.
                        guard abs(value.translation.width) > 2 else { return }
                        let fraction = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                        edit.scrub(lane, toOffset: fraction * lane.spanLength)
                    }
                    .onEnded { value in
                        let fraction = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                        edit.endScrub(lane, atOffset: fraction * lane.spanLength)
                        // The track with the playhead is the one the close-up and the
                        // inspector change. Opened after the seek, so a long track
                        // zooms in around the click.
                        if edit.expandedLaneID != lane.id { edit.toggleExpanded(lane) }
                    }
            )
        }
        .accessibilityLabel("Waveform of \(lane.label)")
    }
}

/// The selected track up close, pinned under the list.
private struct CloseUpSection: View {
    @Environment(AppModel.self) private var model

    let size: LayoutSize

    private var edit: EditModel { model.editModel }

    var body: some View {
        if let lane = edit.expandedLane {
            let settings = edit.adjustments(for: lane)
            VStack(alignment: .leading, spacing: 0) {
                heading(lane)
                    .padding(.vertical, 6)
                // Times as they'll be heard, at the track's speed.
                TimeRuler(start: edit.zoomStart / settings.speed, span: max(0.001, edit.zoomSpan) / settings.speed)
                    .frame(height: 20)
                CloseUp(lane: lane, settings: settings)
                    .frame(height: size == .regular ? 96 : 80)
                    // A drag or a pinch under way belongs to one track.
                    .id(lane.id)
                transport(lane)
                    .padding(.vertical, 8)
            }
        } else {
            Text("Select a track")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
        }
    }

    private func heading(_ lane: EditModel.Lane) -> some View {
        let title = "\(displayName(lane)) · close-up"
        return HStack(spacing: 9) {
            Text(title)
                .font(Theme.serif(size.sectionTitle))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .help(title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button("−") { edit.endTyping(); edit.zoom(by: 1 / 1.5) }
                .disabled(edit.zoomSpan >= lane.spanLength - 0.001)
                .help("Zoom Out (-)")
                .accessibilityLabel("Zoom Out")
            Button("+") { edit.endTyping(); edit.zoom(by: 1.5) }
                .disabled(edit.zoomSpan <= EditModel.minimumZoomSpan + 0.001)
                .help("Zoom In (=)")
                .accessibilityLabel("Zoom In")
            Button("Whole track") { edit.endTyping(); edit.setZoom(span: lane.spanLength) }
                .disabled(edit.zoomSpan >= lane.spanLength - 0.001)
                .accessibilityLabel("Whole track")
        }
        .buttonStyle(.paperSmall)
    }

    /// Play, where the playhead is, and splitting there. The button drops to a
    /// second line when the row gets narrow.
    private func transport(_ lane: EditModel.Lane) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                playback(lane)
                Spacer(minLength: 4)
                splitButton(lane)
            }
            VStack(alignment: .leading, spacing: 6) {
                playback(lane)
                splitButton(lane)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func playback(_ lane: EditModel.Lane) -> some View {
        let player = edit.player
        // Playing on into a piece appended to this track still counts as this one.
        let playingOn = edit.lanes.contains { $0.id == player.trackKey && $0.head == lane.id }
        let isPlaying = player.isPlaying && (player.trackKey == lane.id || playingOn)
        return HStack(spacing: 9) {
            Button {
                edit.endTyping()
                if isPlaying { edit.toggleCurrent() } else { edit.togglePlayback(lane) }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 34, height: 34)
                    .background(Theme.primary, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Play or pause this track")
            .accessibilityLabel(isPlaying ? "Pause \(lane.label)" : "Play \(lane.label)")

            TrackClock(lane: lane)
        }
    }

    private func splitButton(_ lane: EditModel.Lane) -> some View {
        Button {
            edit.endTyping()
            edit.split(lane)
        } label: {
            HStack(spacing: 7) {
                Text("Split at playhead")
                KeyLetter("M")
            }
        }
        .buttonStyle(.paperStandard)
        .accessibilityLabel("Split at playhead")
        .disabled(!edit.canSplit(lane))
        .help("Split at the playhead. Hold Option to split exactly there.")
    }
}

/// How far into the track the playhead is, as heard at its speed, and where that is
/// on the recording.
private struct TrackClock: View {
    @Environment(AppModel.self) private var model

    let lane: EditModel.Lane

    var body: some View {
        let player = model.editModel.player
        let loaded = player.trackKey == lane.id
        // Reading the anchor redraws after a seek while paused.
        let _ = player.anchor
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !(loaded && player.isPlaying))) { _ in
            let reversed = model.editModel.adjustments(for: lane).reversed
            let elapsed = TimeLabel.clock(loaded ? player.elapsed : 0)
            let place = TimeLabel.clock(loaded ? player.position : (reversed ? lane.end : lane.start))
            Text("Track \(elapsed) / \(lane.side == nil ? "Recording" : "Side") \(place)")
                .font(Theme.mono())
                .foregroundStyle(Theme.ink)
                .fixedSize()
        }
    }
}

/// A close-up to place the playhead precisely. Drag to scrub, pinch to zoom.
private struct CloseUp: View {
    @Environment(AppModel.self) private var model
    @State private var pinchStartSpan: Double?
    @State private var dragOffset: Double?

    let lane: EditModel.Lane
    let settings: TrackAdjustments

    private var edit: EditModel { model.editModel }

    /// Levels for a stretch in listening order, turned around for a reversed track.
    private func levels(from offset: Double, span: Double, columns: Int) -> [Float] {
        guard let waveform = edit.waveforms[lane.track.sourceID] else { return [] }
        let a = edit.master(atOffset: offset, in: lane)
        let b = edit.master(atOffset: offset + span, in: lane)
        var levels = waveform.levels(from: min(a, b), to: max(a, b), columns: columns, gainDB: settings.gainDB)
        if settings.reversed { levels.reverse() }
        return levels
    }

    private func draw(_ levels: [Float], in size: CGSize, context: GraphicsContext) {
        let width = size.width / CGFloat(max(1, levels.count))
        for (index, level) in levels.enumerated() {
            let bar = max(1, CGFloat(level) * size.height)
            let rect = CGRect(x: CGFloat(index) * width, y: (size.height - bar) / 2, width: max(0.5, width - 0.5), height: bar)
            context.fill(Path(rect), with: .color(level >= 0.999 ? EditColors.clipped : Theme.waveform))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let start = edit.zoomStart
            let span = max(0.001, edit.zoomSpan)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(levels(from: start, span: span, columns: max(1, Int(size.width / 2))), in: size, context: context)
                }
                TrimOverlay(lane: lane, windowStart: start, windowSpan: span)
                playheadLine(start: start, span: span, width: width, height: geometry.size.height)
                if let dragOffset {
                    Rectangle()
                        .fill(Theme.needle.opacity(0.45))
                        .frame(width: 2, height: geometry.size.height)
                        .offset(x: width * (dragOffset - start) / span)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let offset = start + span * min(1, max(0, value.location.x / max(1, width)))
                        dragOffset = offset
                        if abs(value.translation.width) > 2 { edit.scrub(lane, toOffset: offset, movesPlayhead: false) }
                    }
                    .onEnded { _ in
                        edit.endScrub(lane, atOffset: dragOffset)
                        dragOffset = nil
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = pinchStartSpan ?? edit.zoomSpan
                        pinchStartSpan = base
                        let anchor = edit.player.trackKey == lane.id ? edit.offset(ofMaster: edit.player.position, in: lane) : nil
                        edit.setZoom(span: base / value.magnification, keeping: anchor)
                    }
                    .onEnded { _ in pinchStartSpan = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("Close-up of \(lane.label)")
        }
        .scopeBackground()
    }

    private func playheadLine(start: Double, span: Double, width: CGFloat, height: CGFloat) -> some View {
        let player = edit.player
        let loaded = player.trackKey == lane.id
        // Reading the anchor redraws after a seek while paused.
        let _ = player.anchor
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(loaded && player.isPlaying))) { _ in
            let offset = loaded ? edit.offset(ofMaster: player.position, in: lane) : -1
            let x = width * (offset - start) / span
            Rectangle()
                .fill(Theme.needle)
                .frame(width: 2, height: height)
                .offset(x: x)
                .opacity(loaded && x >= 0 && x <= width ? 1 : 0)
                .onChange(of: offset) { _, _ in edit.follow(lane) }
        }
        .allowsHitTesting(false)
    }
}

/// A track's trims over its waveform: the parts left out are dimmed, and a handle
/// at each edge of what plays can be dragged to trim more or less. `windowStart` and
/// `windowSpan` are the stretch in view, in master seconds in listening order.
private struct TrimOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var draggedStart: Double?
    @State private var draggedEnd: Double?

    let lane: EditModel.Lane
    let windowStart: Double
    let windowSpan: Double

    var body: some View {
        let edit = model.editModel
        let saved = edit.heardCuts(lane)
        let cutStart = draggedStart ?? saved.start
        let cutEnd = draggedEnd ?? saved.end
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let x = { (offset: Double) in CGFloat((offset - windowStart) / max(0.001, windowSpan)) * width }
            let keptFrom = min(width, max(0, x(cutStart)))
            let keptTo = min(width, max(0, x(lane.spanLength - cutEnd)))
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.paper.opacity(0.72))
                    .frame(width: keptFrom, height: height)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(Theme.paper.opacity(0.72))
                    .frame(width: max(0, width - keptTo), height: height)
                    .offset(x: keptTo)
                    .allowsHitTesting(false)
                if !edit.isOnSite {
                    let startX = x(cutStart), endX = x(lane.spanLength - cutEnd)
                    if startX >= -1 && startX <= width + 1 {
                        handle(height: height, pointingRight: true)
                            .offset(x: startX - Self.grip / 2)
                            .gesture(drag(width: width) { offset in
                                let cut = min(max(0, offset), edit.maximumCut(lane, besides: cutEnd))
                                draggedStart = cut
                                edit.scrub(lane, toOffset: cut, movesPlayhead: false)
                            } ended: {
                                edit.endScrub(lane, atOffset: nil)
                                edit.setHeardCuts(lane, start: draggedStart ?? saved.start, end: saved.end)
                            })
                            .help("Drag to trim the start")
                            .accessibilityLabel("Start of \(lane.label)")
                    }
                    if endX >= -1 && endX <= width + 1 {
                        handle(height: height, pointingRight: false)
                            .offset(x: endX - Self.grip / 2)
                            .gesture(drag(width: width) { offset in
                                let cut = min(max(0, lane.spanLength - offset), edit.maximumCut(lane, besides: cutStart))
                                draggedEnd = cut
                                // Heard going into the edge, so the snippet ends where the track will.
                                edit.scrub(lane, toOffset: lane.spanLength - cut, movesPlayhead: false)
                            } ended: {
                                edit.endScrub(lane, atOffset: nil)
                                edit.setHeardCuts(lane, start: saved.start, end: draggedEnd ?? saved.end)
                            })
                            .help("Drag to trim the end")
                            .accessibilityLabel("End of \(lane.label)")
                    }
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .coordinateSpace(.named(TrimOverlay.space))
        }
        // Hold the dragged place until the saved trim arrives, so it doesn't jump back.
        .onChange(of: lane.track.cutStart) { draggedStart = nil; draggedEnd = nil }
        .onChange(of: lane.track.cutEnd) { draggedStart = nil; draggedEnd = nil }
    }

    private static let grip: CGFloat = 14

    /// A line at the edge of what plays, with a tab to grab, in a hit area wider
    /// than it looks.
    private func handle(height: CGFloat, pointingRight: Bool) -> some View {
        ZStack(alignment: pointingRight ? .topLeading : .topTrailing) {
            Rectangle()
                .fill(Theme.needle)
                .frame(width: 2, height: height)
                .frame(maxWidth: .infinity)
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: pointingRight ? 0 : 3,
                bottomTrailingRadius: pointingRight ? 3 : 0,
                topTrailingRadius: 0
            )
            .fill(Theme.needle)
            .frame(width: 7, height: 12)
            .offset(x: pointingRight ? Self.grip / 2 : -Self.grip / 2)
        }
        .frame(width: Self.grip, height: height)
        .contentShape(.rect)
        .pointerStyle(.columnResize)
    }

    private func drag(width: CGFloat, changed: @escaping (Double) -> Void, ended: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(TrimOverlay.space))
            .onChanged { value in
                changed(windowStart + windowSpan * Double(value.location.x / max(1, width)))
            }
            .onEnded { _ in ended() }
    }

    static let space = "trim"
}

/// The selected track's settings and what can be done with it.
private struct Inspector: View {
    @Environment(AppModel.self) private var model

    let size: LayoutSize
    /// Asks to append one track to another, which is confirmed first.
    let append: (EditModel.Lane, EditModel.Lane) -> Void

    private var edit: EditModel { model.editModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            settings
            // As in the mock, the way back sits right under the drag hint, unruled.
            // Both stay at the foot, so the way back is never scrolled out of sight.
            VStack(alignment: .leading, spacing: 0) {
                if edit.expandedLane != nil {
                    HairlineRule()
                    Text("Drag between tracks to reorder. Drop onto a track to append its audio.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                }
                // No inset below: the window footer already sits under it.
                ReturnToSide()
                    .padding(.top, 5)
            }
        }
        .padding(.leading, size == .regular ? 24 : 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.line)
                .frame(width: 1)
                .accessibilityHidden(true)
        }
    }

    /// The part that scrolls, leaving the drag hint and the way back in place under
    /// it. Sized for Track actions to fit at 900 by 692 with a two-line name and
    /// the clipping warning, not yet checked on screen. Smaller windows scroll.
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let lane = edit.expandedLane {
                    heading(lane)
                    TrackSettings(lane: lane)
                        .disabled(edit.isOnSite)
                    SettingsNote(locked: edit.isOnSite)
                        .padding(.vertical, 7)
                    HairlineRule()
                    TrackActions(lane: lane, size: size, append: append)
                        .disabled(edit.isOnSite)
                        // A question about one track isn't left open over another.
                        .id(lane.id)
                } else {
                    Text("Select a track")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 14)
                    SettingsNote(locked: edit.isOnSite)
                        .padding(.vertical, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heading(_ lane: EditModel.Lane) -> some View {
        let place = lane.isAppended ? "Piece \(lane.label)" : "Track \(trackNumberText(lane.number))"
        return VStack(alignment: .leading, spacing: 4) {
            CapLabel(lane.side.map { "\(place) / Side \($0)" } ?? place)
            Text(displayName(lane))
                .font(Theme.serif(size.sectionTitle))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .help(displayName(lane))
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.bottom, 2)
    }
}

/// Goes back to Review, on the recording and moment the playhead is at.
private struct ReturnToSide: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The side of the piece it leaves from, which may not be the one it came in on.
        let side = if let lane = model.editModel.departureLane {
            lane.side
        } else {
            model.selectedItem?.source.side
        }
        Button {
            model.editModel.endTyping()
            model.returnToSide()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left")
                    .accessibilityHidden(true)
                Text(TrackHandoff.returnTitle(side: side))
            }
        }
        .buttonStyle(.paperStandard)
        .accessibilityLabel(TrackHandoff.returnTitle(side: side))
        .help("Review this recording at the same moment")
    }
}

/// Level, speed and direction, and where the trims are.
private struct TrackSettings: View {
    @Environment(AppModel.self) private var model

    let lane: EditModel.Lane

    private var edit: EditModel { model.editModel }
    private var settings: TrackAdjustments { edit.adjustments(for: lane) }

    var body: some View {
        // Trim points are given as they're heard, like the close-up's ruler.
        let cuts = edit.heardCuts(lane)
        VStack(alignment: .leading, spacing: 0) {
            level
            speed
            direction
            KeyValueRow(key: "Trim start", value: TimeText.hundredths(cuts.start / settings.speed),
                        verticalPadding: 4.5)
            KeyValueRow(key: "Trim end", value: TimeText.hundredths((lane.spanLength - cuts.end) / settings.speed),
                        verticalPadding: 4.5)
        }
    }

    /// The value sits above the slider, which leaves the button room for "Measuring…".
    @ViewBuilder private var level: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Level")
                .foregroundStyle(Theme.muted)
                .fixedSize()
            Spacer(minLength: 0)
            Text(Self.decibels(settings.gainDB))
                .foregroundStyle(Theme.ink)
                .fixedSize()
        }
        .font(.system(size: 13))
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { settings.gainDB },
                    // Half-decibel steps, rounded here so the slider shows no tick marks.
                    set: { edit.set(TrackAdjustments(gainDB: ($0 * 2).rounded() / 2, speed: settings.speed, reversed: settings.reversed), for: lane) }
                ),
                in: -18...18
            )
            .frame(minWidth: 80, maxWidth: .infinity)
            .accessibilityLabel("Level of \(lane.label)")
            .accessibilityValue(Self.decibels(settings.gainDB))
            Button(edit.measuring.contains(lane.id) ? "Measuring…" : "Fit") { edit.fitLevel(lane) }
                .buttonStyle(.paperSmall)
                .accessibilityLabel(edit.measuring.contains(lane.id) ? "Measuring…" : "Fit")
                .disabled(edit.measuring.contains(lane.id))
                .help("Raise or lower the level so the loudest moment sits just under the top")
        }
        .padding(.vertical, 3)
        if let peak = edit.loudestPeak(of: lane), peak.decibels + settings.gainDB > -0.1, settings.gainDB > 0 {
            Label(
                peak.exact
                    ? "The loudest moment will clip at this level. Try Fit."
                    : "The loudest moment may clip at this level. Fit measures it exactly.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.attention)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
        HairlineRule()
    }

    /// 1% steps either side of the speed, which is also the menu of presets.
    private var speed: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Speed")
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                Spacer(minLength: 0)
                Button("−") { setSpeed(settings.speed - 0.01) }
                    .buttonStyle(.paperSmall)
                    .help("1% slower")
                    .accessibilityLabel("Slower")
                Menu(Self.percent(settings.speed)) {
                    Picker("Speed preset", selection: Binding(
                        get: { [0.5, 1, 2].first { abs($0 - settings.speed) < 0.0005 } ?? 0 },
                        set: { if $0 > 0 { setSpeed($0) } }
                    )) {
                        Text("½×").tag(0.5)
                        Text("1×").tag(1.0)
                        Text("2×").tag(2.0)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .menuStyle(.borderlessButton)
                .monospacedDigit()
                .fixedSize()
                // Room for the widest value, so − stays put as the value changes.
                .frame(minWidth: 58)
                .help("½× plays a tape recorded at half the speed it was captured at, 2× the reverse")
                .accessibilityLabel("Speed \(Self.percent(settings.speed))")
                Button("+") { setSpeed(settings.speed + 0.01) }
                    .buttonStyle(.paperSmall)
                    .help("1% faster")
                    .accessibilityLabel("Faster")
            }
            .font(.system(size: 13))
            .padding(.vertical, 4)
            HairlineRule()
        }
    }

    private var direction: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Direction")
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                Spacer(minLength: 0)
                Menu(settings.reversed ? "Reversed" : "Forward") {
                    Picker("Direction", selection: Binding(
                        get: { settings.reversed },
                        set: { edit.set(TrackAdjustments(gainDB: settings.gainDB, speed: settings.speed, reversed: $0), for: lane) }
                    )) {
                        Text("Forward").tag(false)
                        Text("Reversed").tag(true)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Reversed plays this track backwards")
                .accessibilityLabel("Direction: \(settings.reversed ? "Reversed" : "Forward")")
            }
            .font(.system(size: 13))
            .padding(.vertical, 5.5)
            HairlineRule()
        }
    }

    private func setSpeed(_ speed: Double) {
        edit.set(TrackAdjustments(gainDB: settings.gainDB, speed: speed, reversed: settings.reversed), for: lane)
    }

    private static func decibels(_ value: Double) -> String {
        value == 0 ? "0 dB" : String(format: "%+.1f dB", value)
    }

    private static func percent(_ speed: Double) -> String {
        let value = speed * 100
        return value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }
}

/// Joining, appending, detaching, moving and resetting, in one menu.
private struct TrackActions: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsJoin = false

    let lane: EditModel.Lane
    let size: LayoutSize
    let append: (EditModel.Lane, EditModel.Lane) -> Void

    private var edit: EditModel { model.editModel }

    var body: some View {
        let targets = edit.appendTargets(for: lane)
        Menu {
            Button("Join with previous…") { edit.endTyping(); confirmsJoin = true }
                .disabled(!edit.canJoin(lane))
                .accessibilityLabel("Join with previous…")

            Menu("Append to another track…") {
                ForEach(targets) { target in
                    let title = "\(trackNumberText(target.number))  \(displayName(target))"
                    Button(title) { append(lane, target) }
                        .accessibilityLabel(title)
                }
            }
            .disabled(targets.isEmpty)
            .help("Play this track straight after another, as one track on the site")

            if lane.isAppended {
                Button("Detach into its own track") { edit.detach(lane) }
                    .accessibilityLabel("Detach into its own track")
            }

            Button("Move up") { edit.move(lane, by: -1) }
                .disabled(!edit.canMove(lane, by: -1))
                .accessibilityLabel("Move up")
            Button("Move down") { edit.move(lane, by: 1) }
                .disabled(!edit.canMove(lane, by: 1))
                .accessibilityLabel("Move down")

            Divider()

            Button("Reset trim") { edit.resetTrim(lane) }
                .disabled(!lane.track.isCut)
                .accessibilityLabel("Reset trim")
            Button("Reset level, speed and direction") { edit.set(.none, for: lane) }
                .disabled(edit.adjustments(for: lane).isNeutral)
                .accessibilityLabel("Reset level, speed and direction")
        } label: {
            TrackActionsLabel(size: size)
        }
        // As a plain button, the menu keeps the serif heading and fills the row.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Track actions")
        .confirmationDialog("Join \(lane.label) onto the track before it?", isPresented: $confirmsJoin) {
            Button("Join Tracks", role: .destructive) { edit.joinWithPrevious(lane) }
        } message: {
            Text("\(lane.label)’s name, description and settings are removed. It takes on the settings of the track before it.")
        }
    }
}

/// The heading that opens the track actions. A view of its own, so it can read
/// whether the menu is enabled.
private struct TrackActionsLabel: View {
    @Environment(\.isEnabled) private var isEnabled

    let size: LayoutSize

    var body: some View {
        HStack(spacing: 8) {
            Text("Track actions")
                .font(Theme.serif(size.sectionTitle))
                .fixedSize()
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 11))
                .accessibilityHidden(true)
        }
        .foregroundStyle(Theme.ink)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .opacity(isEnabled ? 1 : 0.4)
    }
}
