import RemanenceCore
import SwiftUI

/// Every track of a tape as its own lane, with its level, speed and direction.
struct EditView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingAppend: PendingAppend?

    let tape: ShelfTape

    private var edit: EditModel { model.editModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 10)

            if edit.lanes.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening the tracks…")
                        .foregroundStyle(Theme.inkMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(edit.lanes.enumerated()), id: \.element.id) { index, lane in
                            if !lane.isAppended {
                                if edit.hasSides, sideChanges(at: index) {
                                    SideHeader(lane: lane, locked: edit.isOnSite)
                                        .padding(.top, index == 0 ? 0 : 12)
                                }
                                DropGap(locked: edit.isOnSite) { moving in
                                    edit.move(moving, before: lane.number - 1)
                                }
                            }
                            LaneView(lane: lane) { moving in
                                guard let moving = edit.lanes.first(where: { $0.id == moving }),
                                      edit.canAppend(moving, to: lane) else { return false }
                                pendingAppend = PendingAppend(moving: moving, target: edit.headLane(of: lane))
                                return true
                            }
                            .padding(.leading, lane.isAppended ? 28 : 0)
                            .padding(.top, lane.isAppended ? 8 : 0)
                        }
                        DropGap(locked: edit.isOnSite) { moving in
                            edit.move(moving, before: edit.headLanes.count)
                        }
                        EditHints()
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Theme.paper)
        .task(id: tape.id) { await edit.observe(tapeID: tape.id) }
        .onDisappear { edit.leave() }
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

    /// Whether this lane starts a new side, counting only tracks of their own.
    private func sideChanges(at index: Int) -> Bool {
        let previous = edit.lanes[..<index].last { !$0.isAppended }
        return previous == nil || previous?.side != edit.lanes[index].side
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                model.leaveEdit()
            } label: {
                Label(model.backLabel, systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .tint(Theme.accent)

            Text(tape.tape.title)
                .font(Theme.display(22))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .help(tape.tape.title)

            Text(edit.isOnSite
                 ? "This tape is on the site. Its audio there can’t be replaced yet, so these settings are locked."
                 : "Level, speed and direction are heard here and applied when you push. Your masters never change.")
                .font(.system(size: 12))
                .foregroundStyle(edit.isOnSite ? Theme.attention : Theme.inkMuted)
                .lineLimit(2)
        }
    }
}

/// A side's heading. Double-click it to rename the side.
private struct SideHeader: View {
    @Environment(AppModel.self) private var model
    @State private var isEditing = false
    @State private var name = ""
    @FocusState private var isFocused: Bool

    let lane: EditModel.Lane
    let locked: Bool

    var body: some View {
        if isEditing {
            HStack(spacing: 6) {
                Text("Side")
                    .font(Theme.display(18))
                    .foregroundStyle(Theme.ink)
                TextField("B", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .frame(width: 70)
                    .focused($isFocused)
                    .onSubmit { finish(save: true) }
                    .onExitCommand { finish(save: false) }
                    .onChange(of: isFocused) { _, focused in if !focused { finish(save: true) } }
            }
            .onAppear { DispatchQueue.main.async { isFocused = true } }
        } else {
            Text(lane.side.map { "Side \($0)" } ?? "Recording")
                .font(Theme.display(18))
                .foregroundStyle(Theme.ink)
                .contentShape(.rect)
                .onTapGesture(count: 2) {
                    guard !locked, lane.side != nil else { return }
                    name = lane.side ?? ""
                    isEditing = true
                }
                .help(locked ? "" : "Double-click to rename this side")
        }
    }

    private func finish(save: Bool) {
        guard isEditing else { return }
        isEditing = false
        let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard save, !new.isEmpty, new != lane.side, let library = model.library else { return }
        let sourceID = lane.track.sourceID
        Task {
            do {
                try await Task.detached { try await library.renameSide(sourceID: sourceID, to: new) }.value
            } catch {
                model.message = error.localizedDescription
            }
        }
    }
}

/// The space between two tracks. Dropping a track here moves it to this place.
private struct DropGap: View {
    @State private var isTargeted = false

    let locked: Bool
    let onDrop: (String) -> Void

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 12)
            .frame(maxWidth: .infinity)
            .overlay {
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

/// A track dropped onto another, waiting for confirmation.
private struct PendingAppend {
    let moving: EditModel.Lane
    let target: EditModel.Lane
}

private struct LaneView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var confirmsJoin = false
    @State private var isDropTarget = false
    @State private var isEditingName = false
    @FocusState private var isNaming: Bool

    let lane: EditModel.Lane
    /// Called with the dragged lane's id when a track is dropped here.
    var onDrop: (String) -> Bool = { _ in false }

    private var edit: EditModel { model.editModel }
    private var settings: TrackAdjustments { edit.adjustments(for: lane) }
    private var isLoaded: Bool { edit.player.trackKey == lane.id }
    private var isPlaying: Bool { isLoaded && edit.player.isPlaying }
    private var locked: Bool { edit.isOnSite }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if lane.isAppended {
                Label("Then, as part of the same track", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkMuted)
            }
            titleRow
            if edit.expandedLaneID == lane.id {
                ZoomedLane(lane: lane, settings: settings)
            } else {
                LaneWaveform(lane: lane, settings: settings)
                    .frame(height: 64)
            }
            controls
                .disabled(locked)
            warnings
        }
        .padding(12)
        .background(Theme.card, in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTarget ? Theme.accent : isLoaded ? Theme.accent.opacity(0.6) : Theme.board.opacity(0.6),
                    lineWidth: isDropTarget ? 2 : 1
                )
        )
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first else { return false }
            return onDrop(first)
        } isTargeted: { isDropTarget = $0 && !locked }
        .onAppear { name = lane.track.name ?? "" }
        .onChange(of: lane.track.name) { _, updated in
            if !isNaming { name = updated ?? "" }
        }
        .onChange(of: isNaming) { _, naming in
            if !naming, isEditingName {
                isEditingName = false
                edit.rename(lane, to: name)
            }
        }
        .confirmationDialog("Join \(lane.label) onto the track before it?", isPresented: $confirmsJoin) {
            Button("Join Tracks", role: .destructive) { edit.joinWithPrevious(lane) }
        } message: {
            Text("\(lane.label)’s name, description and settings are removed. It takes on the settings of the track before it.")
        }
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            if !locked {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 16, height: 30)
                    .contentShape(.rect)
                    .draggable(lane.id) {
                        Text(lane.track.name.flatMap { $0.isEmpty ? nil : $0 } ?? lane.label)
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.card, in: .rect(cornerRadius: 6))
                    }
                    .help("Drag between tracks to move it, or onto a track to append it to that track's end")
                    .accessibilityLabel("Drag \(lane.label) onto another track")
            }
            Button {
                edit.togglePlayback(lane)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 30, height: 30)
                    .background(Theme.ink, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause \(lane.label)" : "Play \(lane.label)")

            if !lane.isAppended {
                Text("\(lane.number)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: 16, alignment: .trailing)
                    .fixedSize()
                    .help("Its place on the site")
            }
            Text(lane.label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
                .help("Where it is on its recording")

            nameField

            if lane.pieceCount > 1, !lane.isAppended {
                Text("\(lane.pieceCount) pieces · \(TimeLabel.clock(lane.totalDuration))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize()
                    .help("How long the whole track plays, with the pieces appended to it")
            }
            if lane.track.isCut {
                Label("Trimmed", systemImage: "scissors")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize()
                    .help(trimHelp)
            }
            LaneClock(lane: lane, settings: settings)

            Button {
                edit.toggleExpanded(lane)
            } label: {
                Image(systemName: edit.expandedLaneID == lane.id
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help(edit.expandedLaneID == lane.id ? "Close up" : "Open up and zoom in, to split precisely")
            .accessibilityLabel(edit.expandedLaneID == lane.id ? "Close \(lane.label)" : "Zoom into \(lane.label)")

            Menu {
                Button("Split at Playhead", systemImage: "scissors") { edit.split(lane) }
                    .disabled(!edit.canSplit(lane))
                Button("Join with Previous Track", systemImage: "arrow.up.to.line") { confirmsJoin = true }
                    .disabled(!edit.canJoin(lane))
                if lane.isAppended {
                    Button("Detach into Its Own Track", systemImage: "arrow.uturn.left") { edit.detach(lane) }
                        .disabled(locked)
                }
                Divider()
                Button("Reset Trim") { edit.resetTrim(lane) }
                    .disabled(!lane.track.isCut || locked)
                Divider()
                Button("Move Up", systemImage: "arrow.up") { edit.move(lane, by: -1) }
                    .disabled(!edit.canMove(lane, by: -1))
                Button("Move Down", systemImage: "arrow.down") { edit.move(lane, by: 1) }
                    .disabled(!edit.canMove(lane, by: 1))
                Divider()
                Button("Reset Level, Speed and Direction") { edit.set(.none, for: lane) }
                    .disabled(settings.isNeutral || locked)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for this track")
        }
    }

    /// The track's name, which becomes editable on a double-click, so typing a key
    /// meant for edit mode never lands in it.
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
            Text(name.isEmpty ? placeholder : name)
                .font(.system(size: 14))
                .foregroundStyle(name.isEmpty ? Theme.inkMuted : Theme.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture(count: 2) {
                    name = lane.track.name ?? ""
                    isEditingName = true
                }
                .help("Double-click to rename")
                .accessibilityLabel("Name of \(lane.label): \(name.isEmpty ? placeholder : name)")
                .accessibilityAction(named: "Rename") { isEditingName = true }
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                levelControl
                speedControl
                reverseControl
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    levelControl
                    reverseControl
                }
                speedControl
            }
        }
        .font(.system(size: 12))
    }

    private var levelControl: some View {
        HStack(spacing: 6) {
            Text("Level")
                .foregroundStyle(Theme.inkMuted)
                .fixedSize()
            Slider(
                value: Binding(
                    get: { settings.gainDB },
                    // Half-decibel steps, rounded here so the slider shows no tick marks.
                    set: { edit.set(TrackAdjustments(gainDB: ($0 * 2).rounded() / 2, speed: settings.speed, reversed: settings.reversed), for: lane) }
                ),
                in: -18...18
            )
            .frame(width: 130)
            .accessibilityLabel("Level of \(lane.label)")
            .accessibilityValue(Self.decibels(settings.gainDB))
            Text(Self.decibels(settings.gainDB))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(width: 54, alignment: .trailing)
                .fixedSize()
            Button(edit.measuring.contains(lane.id) ? "Measuring…" : "Fit") { edit.fitLevel(lane) }
                .controlSize(.small)
                .fixedSize()
                .disabled(edit.measuring.contains(lane.id))
                .help("Raise or lower the level so the loudest moment sits just under the top")
        }
    }

    private var speedControl: some View {
        HStack(spacing: 6) {
            Text("Speed")
                .foregroundStyle(Theme.inkMuted)
                .fixedSize()
            Button("Slower", systemImage: "minus") { setSpeed(settings.speed - 0.01) }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help("1% slower")
            Text(Self.percent(settings.speed))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(width: 44)
                .fixedSize()
                .accessibilityLabel("Speed \(Self.percent(settings.speed))")
            Button("Faster", systemImage: "plus") { setSpeed(settings.speed + 0.01) }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help("1% faster")
            Picker("Speed preset", selection: Binding(
                get: { [0.5, 1, 2].first { abs($0 - settings.speed) < 0.0005 } ?? 0 },
                set: { if $0 > 0 { setSpeed($0) } }
            )) {
                Text("½×").tag(0.5)
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .help("½× plays a tape recorded at half the speed it was captured at, 2× the reverse")
        }
    }

    private var reverseControl: some View {
        Toggle(isOn: Binding(
            get: { settings.reversed },
            set: { edit.set(TrackAdjustments(gainDB: settings.gainDB, speed: settings.speed, reversed: $0), for: lane) }
        )) {
            Label("Reverse", systemImage: "arrow.uturn.backward")
                .fixedSize()
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("Play this track backwards")
    }

    @ViewBuilder private var warnings: some View {
        if let peak = edit.loudestPeak(of: lane), peak.decibels + settings.gainDB > -0.1, settings.gainDB > 0 {
            Label(
                peak.exact
                    ? "The loudest moment will clip at this level. Try Fit."
                    : "The loudest moment may clip at this level. Fit measures it exactly.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.attention)
        }
    }

    private func setSpeed(_ speed: Double) {
        edit.set(TrackAdjustments(gainDB: settings.gainDB, speed: speed, reversed: settings.reversed), for: lane)
    }

    static func decibels(_ value: Double) -> String {
        value == 0 ? "0 dB" : String(format: "%+.1f dB", value)
    }

    static func percent(_ speed: Double) -> String {
        let value = speed * 100
        return value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }
}

/// Elapsed and total time in listening order, at the adjusted speed.
private struct LaneClock: View {
    @Environment(AppModel.self) private var model

    let lane: EditModel.Lane
    let settings: TrackAdjustments

    var body: some View {
        let player = model.editModel.player
        let loaded = player.trackKey == lane.id
        let total = settings.duration(of: lane.end - lane.start)
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: !(loaded && player.isPlaying))) { _ in
            let elapsed = loaded ? player.elapsed : 0
            Text(loaded ? "\(TimeLabel.clock(elapsed)) / \(TimeLabel.clock(total))" : TimeLabel.clock(total))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Theme.inkMuted)
                .fixedSize()
        }
    }
}

/// A track's waveform drawn as it will sound: raised or lowered, and turned around
/// when reversed. Click or drag to move the playhead.
private struct LaneWaveform: View {
    @Environment(AppModel.self) private var model

    let lane: EditModel.Lane
    let settings: TrackAdjustments

    private static let color = Color(red: 0.42, green: 0.384, blue: 0.337)
    private static let clipped = Color(red: 0.604, green: 0.184, blue: 0.102)

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
                        context.fill(Path(rect), with: .color(level >= 0.999 ? Self.clipped : Self.color))
                    }
                }
                if loaded {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying)) { _ in
                        let fraction = edit.offset(ofMaster: player.position, in: lane) / lane.spanLength
                        Rectangle()
                            .fill(Color(red: 0.659, green: 0.196, blue: 0.102))
                            .frame(width: 2, height: geometry.size.height)
                            .offset(x: max(0, min(1, fraction)) * (geometry.size.width - 2))
                    }
                    .allowsHitTesting(false)
                }
                TrimOverlay(lane: lane, windowStart: 0, windowSpan: lane.spanLength)
            }
            .contentShape(.rect)
            .simultaneousGesture(TapGesture(count: 2).onEnded { edit.toggleExpanded(lane) })
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
                    }
            )
        }
        .background(Theme.paper.opacity(0.7), in: .rect(cornerRadius: 4))
        .accessibilityLabel("Waveform of \(lane.label)")
    }
}

/// A track opened up: a close-up to place the playhead precisely, the whole track
/// below it showing where the close-up is, and the zoom controls.
private struct ZoomedLane: View {
    @Environment(AppModel.self) private var model
    @State private var pinchStartSpan: Double?
    @State private var dragOffset: Double?

    let lane: EditModel.Lane
    let settings: TrackAdjustments

    private static let color = Color(red: 0.42, green: 0.384, blue: 0.337)
    private static let clipped = Color(red: 0.604, green: 0.184, blue: 0.102)
    private static let playhead = Color(red: 0.659, green: 0.196, blue: 0.102)

    private var edit: EditModel { model.editModel }
    private var length: Double { lane.spanLength }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            closeUp
                .frame(height: 170)
            overview
                .frame(height: 28)
            zoomBar
        }
    }

    /// Levels for a stretch in listening order, turned around for a reversed track.
    private func levels(from offset: Double, span: Double, columns: Int) -> [Float] {
        guard let waveform = edit.waveforms[lane.track.sourceID] else { return [] }
        let a = edit.master(atOffset: offset, in: lane)
        let b = edit.master(atOffset: offset + span, in: lane)
        var levels = waveform.levels(from: min(a, b), to: max(a, b), columns: columns, gainDB: settings.gainDB)
        if settings.reversed { levels.reverse() }
        return levels
    }

    private func draw(_ levels: [Float], in size: CGSize, context: GraphicsContext, top: CGFloat = 0) {
        let width = size.width / CGFloat(max(1, levels.count))
        let height = size.height - top
        for (index, level) in levels.enumerated() {
            let bar = max(1, CGFloat(level) * height)
            let rect = CGRect(x: CGFloat(index) * width, y: top + (height - bar) / 2, width: max(0.5, width - 0.5), height: bar)
            context.fill(Path(rect), with: .color(level >= 0.999 ? Self.clipped : Self.color))
        }
    }

    private var closeUp: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let start = edit.zoomStart
            let span = max(0.001, edit.zoomSpan)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(levels(from: start, span: span, columns: max(1, Int(size.width / 2))), in: size, context: context, top: 22)
                }
                // Times as they'll be heard, at the track's speed.
                TimeRuler(start: start / settings.speed, span: span / settings.speed, width: width)
                    .allowsHitTesting(false)
                TrimOverlay(lane: lane, windowStart: start, windowSpan: span)
                playheadLine(start: start, span: span, width: width, height: geometry.size.height)
                if let dragOffset {
                    Rectangle()
                        .fill(Self.playhead.opacity(0.45))
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
        .background(Theme.paper.opacity(0.7), in: .rect(cornerRadius: 4))
        .clipShape(.rect(cornerRadius: 4))
    }

    private func playheadLine(start: Double, span: Double, width: CGFloat, height: CGFloat) -> some View {
        let player = edit.player
        let loaded = player.trackKey == lane.id
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(loaded && player.isPlaying))) { _ in
            let offset = loaded ? edit.offset(ofMaster: player.position, in: lane) : -1
            let x = width * (offset - start) / span
            Rectangle()
                .fill(Self.playhead)
                .frame(width: 2, height: height)
                .offset(x: x)
                .opacity(loaded && x >= 0 && x <= width ? 1 : 0)
                .onChange(of: offset) { _, _ in edit.follow(lane) }
        }
        .allowsHitTesting(false)
    }

    private var overview: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    draw(levels(from: 0, span: length, columns: max(1, Int(size.width / 2))), in: size, context: context)
                }
                Rectangle()
                    .fill(Theme.accent.opacity(0.14))
                    .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1))
                    .frame(width: max(4, width * edit.zoomSpan / length), height: geometry.size.height)
                    .offset(x: width * edit.zoomStart / length)
                    .allowsHitTesting(false)
                TrimOverlay(lane: lane, windowStart: 0, windowSpan: length, showsHandles: false)
                playheadLine(start: 0, span: length, width: width, height: geometry.size.height)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    if value.translation == .zero { edit.endTyping() }
                    let offset = length * min(1, max(0, value.location.x / max(1, width)))
                    edit.moveZoom(to: offset - edit.zoomSpan / 2)
                }
            )
            .accessibilityElement()
            .accessibilityLabel("Whole of \(lane.label)")
        }
        .background(Theme.paper.opacity(0.5), in: .rect(cornerRadius: 4))
        .clipShape(.rect(cornerRadius: 4))
    }

    private var zoomBar: some View {
        HStack(spacing: 8) {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { edit.zoom(by: 1 / 1.5) }
                .labelStyle(.iconOnly)
                .disabled(edit.zoomSpan >= length - 0.001)
            Button("Zoom In", systemImage: "plus.magnifyingglass") { edit.zoom(by: 1.5) }
                .labelStyle(.iconOnly)
                .disabled(edit.zoomSpan <= EditModel.minimumZoomSpan + 0.001)
            Button("Whole Track") { edit.setZoom(span: length) }
                .disabled(edit.zoomSpan >= length - 0.001)
            Text("Showing \(TimeLabel.clock(edit.zoomSpan / settings.speed))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize()
            Spacer(minLength: 8)
            Text("Click to place the playhead, then split. Drag the edges to trim. Pinch or press − = to zoom, swipe to move.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            Button("Split Here", systemImage: "scissors") { edit.split(lane) }
                .disabled(!edit.canSplit(lane))
                .help("Split at the playhead. Hold Option to split exactly there.")
                .fixedSize()
        }
        .controlSize(.small)
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
    var showsHandles = true

    private static let handleColor = Color(red: 0.659, green: 0.196, blue: 0.102)

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
                if showsHandles && !edit.isOnSite {
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
                .fill(Self.handleColor)
                .frame(width: 2, height: height)
                .frame(maxWidth: .infinity)
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: pointingRight ? 0 : 3,
                bottomTrailingRadius: pointingRight ? 3 : 0,
                topTrailingRadius: 0
            )
            .fill(Self.handleColor)
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

private struct EditHints: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach([("Space", "Play"), ("← →", "Skip 5 s"), ("M", "Split at playhead"), ("⌥", "Split exactly"), ("⇤ ⇥", "Drag edges to trim"), ("- =", "Zoom"), ("esc", "Close up")], id: \.0) { key, label in
                HStack(spacing: 4) {
                    Text(key)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.card, in: .rect(cornerRadius: 3))
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkMuted)
                }
                .fixedSize()
            }
        }
    }
}
