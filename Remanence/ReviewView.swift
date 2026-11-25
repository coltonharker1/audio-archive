import RemanenceCore
import SwiftUI

/// Where you mark what's on a tape: scrub the waveform, place markers, name tracks.
struct ReviewView: View {
    @Environment(AppModel.self) private var model

    @Binding var showsTracks: Bool
    let size: LayoutSize

    private var review: ReviewModel { model.reviewModel }
    private var sourceID: Int64? { model.selectedItem?.source.id }

    /// The close-up takes whatever height is left, but never less than this.
    private static let minimumCloseUp: CGFloat = 110

    var body: some View {
        Group {
            if review.isReady, let waveform = review.waveform {
                HStack(alignment: .top, spacing: size == .regular ? 28 : 16) {
                    // Scrolls only when the window is too short for all of it.
                    ViewThatFits(in: .vertical) {
                        side(waveform)
                        ScrollView { side(waveform) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    if showsTracks, let tape = model.selectedTape {
                        TrackColumn(tape: tape, size: size)
                            .frame(width: size.rightColumn)
                    }
                }
                .padding(.horizontal, 28)
            } else {
                preparing
            }
        }
        .background(Theme.paper)
        .task(id: sourceID) {
            if let sourceID { await review.observe(sourceID: sourceID) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsTracks.toggle()
                } label: {
                    Label("Tracks", systemImage: "sidebar.trailing")
                }
                .help(showsTracks ? "Hide tracks" : "Show tracks")
            }
        }
    }

    private var preparing: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Reading the waveform…")
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The whole side, the close-up, and what can be done at the playhead.
    private func side(_ waveform: Waveform) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                sectionTitle(sideHeading(model.selectedItem))
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text("Whole side")
                    Text(TimeLabel.clock(review.duration))
                }
                .font(Theme.mono())
                .foregroundStyle(Theme.ink)
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
            .padding(.bottom, 6)

            OverviewStrip(waveform: waveform)
                .frame(height: 58)
            OverviewRuler(duration: review.duration)

            HStack(spacing: 9) {
                sectionTitle("Close-up")
                Spacer(minLength: 0)
                zoomButton("−", label: "Zoom Out", key: "-", factor: 1.5)
                zoomButton("+", label: "Zoom In", key: "=", factor: 1 / 1.5)
            }
            .padding(.top, 4)

            TimeRuler(start: review.zoomStart, span: max(review.zoomSpan, 0.001))
                .frame(height: 20)
            ZoomedWaveform(waveform: waveform)
                .frame(minHeight: Self.minimumCloseUp, idealHeight: Self.minimumCloseUp, maxHeight: .infinity)

            TransportRow()
                .padding(.vertical, 6)
            HairlineRule()
            MarkerRow()
                .padding(.vertical, 6)
            TrimRow()
        }
        .padding(.vertical, 8)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(Theme.serif(size.sectionTitle))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .help(title)
            .accessibilityAddTraits(.isHeader)
    }

    private func zoomButton(_ symbol: String, label: String, key: String, factor: Double) -> some View {
        Button(symbol) {
            endTyping()
            review.setZoom(span: review.zoomSpan * factor, keeping: model.player.preciseTime)
        }
        .buttonStyle(.paperSmall)
        .help("\(label) (\(key))")
        .accessibilityLabel(label)
    }
}

/// Reads the player every frame, so the clock doesn't redraw the whole screen.
private struct PlayheadClock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Reading currentTime also redraws after a seek while paused, when the
        // timeline itself isn't running.
        let _ = model.player.currentTime
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !model.player.isPlaying)) { _ in
            let time = TimeLabel.clock(model.player.preciseTime)
            let length = TimeLabel.clock(model.reviewModel.duration)
            Text("\(time) / \(length)")
                .font(Theme.mono())
                .foregroundStyle(Theme.ink)
                .fixedSize()
                .accessibilityLabel("Position \(time) of \(length)")
        }
    }
}

enum ReviewTime {
    /// `12:04.3`, with tenths for placing markers.
    static func precise(_ seconds: Double) -> String { TimeText.precise(seconds) }
}

private enum WaveformColors {
    static let kept = Theme.waveform
    static let trimmed = Color(red: 0.827, green: 0.788, blue: 0.69)
    static let playhead = Theme.needle
    static let selected = Theme.accent
}

/// Draws levels as mirrored bars in a rectangle.
private func drawLevels(
    _ levels: [Float],
    in size: CGSize,
    context: GraphicsContext,
    color: (Int) -> Color
) {
    guard !levels.isEmpty else { return }
    let width = size.width / CGFloat(levels.count)
    for (index, level) in levels.enumerated() {
        let height = max(1, CGFloat(level) * size.height)
        let rect = CGRect(
            x: CGFloat(index) * width,
            y: (size.height - height) / 2,
            width: max(0.5, width - 0.5),
            height: height
        )
        context.fill(Path(rect), with: .color(color(index)))
    }
}

/// The whole tape, with the zoomed stretch shown. Drag to move around.
private struct OverviewStrip: View {
    @Environment(AppModel.self) private var model

    let waveform: Waveform

    private var review: ReviewModel { model.reviewModel }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // The strip is built once more after the review is cleared for a reload,
            // so the length then comes from the waveform being drawn. A stand-in
            // near zero would make the zoom box millions of points wide.
            let duration = review.duration > 0 ? review.duration : waveform.duration
            let trimStart = review.review?.trimStart ?? 0
            let trimEnd = review.review?.trimEnd ?? duration

            if duration > 0 {
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let columns = Waveform.columns(forWidth: min(size.width, width))
                        let levels = waveform.levels(from: 0, to: duration, columns: columns, style: .average)
                        drawLevels(levels, in: size, context: context) { index in
                            let time = duration * (Double(index) + 0.5) / Double(columns)
                            return time >= trimStart && time <= trimEnd ? WaveformColors.kept : WaveformColors.trimmed
                        }
                    }

                    Rectangle()
                        .fill(Theme.accent.opacity(0.14))
                        .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1))
                        .frame(
                            width: Waveform.markerWidth(of: review.zoomSpan, in: duration, stripWidth: width),
                            height: geometry.size.height
                        )
                        .offset(x: width * review.zoomStart / duration)

                    ForEach(review.review?.markers ?? []) { marker in
                        Rectangle()
                            .fill(marker.id == review.selectedMarkerID ? WaveformColors.selected : Theme.ink)
                            .frame(width: 2, height: geometry.size.height)
                            .offset(x: width * marker.time / duration)
                    }

                    PlayheadLine(duration: duration, start: 0, span: duration, width: width, height: geometry.size.height)
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        if value.translation == .zero { endTyping() }
                        let time = max(0, min(duration, duration * value.location.x / width))
                        review.moveZoom(to: time - review.zoomSpan / 2)
                        review.scrub(to: time)
                    }
                    .onEnded { _ in review.endScrub() }
                )
                .accessibilityElement()
                .accessibilityLabel("Whole tape")
                .accessibilityValue("Playing at \(TimeLabel.clock(model.player.currentTime)) of \(TimeLabel.clock(duration))")
            }
        }
        .scopeBackground()
    }
}

/// The start, the thirds and the end of the side, under the whole of it.
private struct OverviewRuler: View {
    let duration: Double

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { third in
                if third > 0 { Spacer(minLength: 4) }
                Text(TimeLabel.clock(duration * Double(third) / 3))
                    .fixedSize()
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Theme.muted)
        .padding(.vertical, 3)
        .accessibilityHidden(true)
    }
}

private struct PlayheadLine: View {
    @Environment(AppModel.self) private var model

    let duration: Double
    let start: Double
    let span: Double
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let _ = model.player.currentTime
        TimelineView(.animation(paused: !model.player.isPlaying)) { _ in
            let time = model.player.preciseTime
            let x = width * (time - start) / max(span, 0.001)
            Rectangle()
                .fill(WaveformColors.playhead)
                .frame(width: 2, height: height)
                .overlay(alignment: .top) {
                    NeedleHead()
                        .fill(WaveformColors.playhead)
                        .frame(width: 8, height: 7)
                }
                .offset(x: x)
                .opacity(x >= 0 && x <= width ? 1 : 0)
                .onChange(of: time) { _, now in
                    // Keep the playhead in view as it plays.
                    if span < duration, model.player.isPlaying, !model.reviewModel.isHearingJoin {
                        if span == model.reviewModel.zoomSpan { model.reviewModel.showTime(now) }
                    }
                }
        }
        .allowsHitTesting(false)
    }
}

/// The pointed head at the top of the playhead.
private struct NeedleHead: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// A close-up for placing markers. Drag to scrub, pinch to zoom.
private struct ZoomedWaveform: View {
    @Environment(AppModel.self) private var model
    @State private var pinchStartSpan: Double?

    let waveform: Waveform

    /// Space above the bars for the marker flags.
    private static let flagRoom: CGFloat = 18

    private var review: ReviewModel { model.reviewModel }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let start = review.zoomStart
            let span = max(review.zoomSpan, 0.001)
            let trimStart = review.review?.trimStart ?? 0
            let trimEnd = review.review?.trimEnd ?? review.duration

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let columns = Waveform.columns(forWidth: size.width)
                    let levels = waveform.levels(from: start, to: start + span, columns: columns)
                    // The padding below already leaves the flags their room.
                    drawLevels(levels, in: size, context: context) { index in
                        let time = start + span * (Double(index) + 0.5) / Double(columns)
                        return time >= trimStart && time <= trimEnd ? WaveformColors.kept : WaveformColors.trimmed
                    }
                }
                .padding(.top, Self.flagRoom)

                PlayheadLine(duration: review.duration, start: start, span: span, width: width, height: height)

                ForEach(review.review?.markers ?? []) { marker in
                    let x = width * (marker.time - start) / span
                    if x >= -40, x <= width + 40 {
                        MarkerFlag(
                            marker: marker, number: review.trackNumber(startingAt: marker),
                            width: width, span: span, height: height
                        )
                        .offset(x: x)
                    }
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if value.translation == .zero { endTyping() }
                        let time = start + span * value.location.x / width
                        review.selectedMarkerID = nil
                        review.scrub(to: time)
                    }
                    .onEnded { _ in review.endScrub() }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = pinchStartSpan ?? review.zoomSpan
                        pinchStartSpan = base
                        review.setZoom(span: base / value.magnification, keeping: model.player.preciseTime)
                    }
                    .onEnded { _ in pinchStartSpan = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("Zoomed waveform")
            .accessibilityValue("Showing \(TimeLabel.clock(start)) to \(TimeLabel.clock(start + span))")
        }
        .scopeBackground()
    }
}

struct TimeRuler: View {
    let start: Double
    let span: Double
    /// The width the times are spread over. Nil takes the width the ruler is given.
    var width: CGFloat?

    var body: some View {
        if let width {
            marks(over: width)
        } else {
            GeometryReader { geometry in
                marks(over: geometry.size.width)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .clipped()
            }
        }
    }

    private func marks(over width: CGFloat) -> some View {
        let target = span / max(1, Double(width) / 90)
        let step: Double = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600].first { $0 >= target } ?? 7200
        let first = (start / step).rounded(.up) * step
        let times = Array(stride(from: first, through: start + span, by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(times, id: \.self) { time in
                Text(TimeLabel.clock(time))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                    .offset(x: width * (time - start) / span + 3, y: 4)
            }
        }
    }
}

/// A draggable marker, flagged with the number of the track it starts. While it's
/// dragged the flag shows the time instead.
private struct MarkerFlag: View {
    @Environment(AppModel.self) private var model
    @State private var dragTime: Double?

    let marker: Marker
    /// Nil for a marker that starts no track, such as one in a trimmed-off part.
    let number: Int?
    let width: CGFloat
    let span: Double
    let height: CGFloat

    private var isSelected: Bool { model.reviewModel.selectedMarkerID == marker.id }

    private var label: String {
        if let dragTime { return ReviewTime.precise(dragTime) }
        return number.map(trackNumberText) ?? ReviewTime.precise(marker.time)
    }

    var body: some View {
        let color = isSelected ? WaveformColors.selected : Theme.ink
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color)
                .frame(width: 2, height: height)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.paper)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .frame(minWidth: 24, alignment: .leading)
                .background(color, in: .rect(cornerRadius: 3))
                .fixedSize()
        }
        .offset(x: dragTime.map { width * ($0 - marker.time) / span } ?? 0)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if dragTime == nil { endTyping() }
                    model.reviewModel.selectedMarkerID = marker.id
                    let change = span * value.translation.width / width
                    dragTime = max(0.01, min(model.reviewModel.duration - 0.01, marker.time + change))
                }
                .onEnded { _ in
                    if let dragTime, let id = marker.id {
                        model.reviewModel.moveMarker(id: id, to: dragTime, snapping: true)
                    }
                    dragTime = nil
                }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                endTyping()
                model.reviewModel.select(marker)
            }
        )
        .accessibilityElement()
        .accessibilityLabel("\(markerName(number)) at \(TimeLabel.clock(marker.time))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.reviewModel.select(marker) }
    }
}

/// `02`, as tracks and their markers are numbered.
func trackNumberText(_ number: Int) -> String {
    String(format: "%02d", number)
}

/// `Marker 02`, named for the track it starts.
private func markerName(_ number: Int?) -> String {
    number.map { "Marker \(trackNumberText($0))" } ?? "Marker"
}

/// What the side is called. It's the side's own name, so renaming its opening track
/// doesn't change it. The recording's name stands in only when the side has none.
private func sideHeading(_ item: ShelfTape.Item?) -> String {
    guard let item else { return "Recording" }
    return item.source.side.map { "Side \($0)" } ?? item.name
}

/// Takes the keyboard away from a name being typed, so keys reach Review again.
@MainActor
private func endTyping() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

/// Play, the clock, and adding a marker. The checkbox drops to a second line when
/// the row gets narrow.
private struct TransportRow: View {
    @Environment(AppModel.self) private var model

    private var review: ReviewModel { model.reviewModel }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                playback
                Spacer(minLength: 4)
                snapToggle
                addButton
            }
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 9) {
                    playback
                    Spacer(minLength: 4)
                    addButton
                }
                snapToggle
            }
        }
    }

    private var playback: some View {
        HStack(spacing: 9) {
            Button {
                endTyping()
                review.togglePlayback()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 34, height: 34)
                    .background(Theme.primary, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Play or pause (Space)")
            .accessibilityLabel(model.player.isPlaying ? "Pause" : "Play")

            PlayheadClock()
        }
    }

    private var snapToggle: some View {
        @Bindable var review = review
        return Toggle("Snap to quiet", isOn: $review.snapsToQuiet)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .foregroundStyle(Theme.ink)
            .fixedSize()
            .help("New markers settle into the nearest quiet moment. Hold Option to place one exactly.")
    }

    private var addButton: some View {
        Button {
            endTyping()
            review.addMarkerAtPlayhead()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "flag.fill")
                    .accessibilityHidden(true)
                Text("Add marker")
                KeyLetter("M")
            }
        }
        .buttonStyle(.paperStandard)
        .help("Add a marker at the playhead (M)")
        .accessibilityLabel("Add marker")
    }
}

/// The key that does what a button does.
struct KeyLetter: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.muted)
    }
}

/// The selected marker and what can be done with it. With none selected it holds the
/// same height, so the close-up doesn't change size as markers are picked.
private struct MarkerRow: View {
    @Environment(AppModel.self) private var model

    private var review: ReviewModel { model.reviewModel }

    var body: some View {
        if let marker = review.selectedMarker {
            row(number: review.trackNumber(startingAt: marker), time: marker.time)
        } else {
            row(number: 1, time: 0)
                .hidden()
                .overlay(alignment: .leading) {
                    Text("Press M to mark where a track starts.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
        }
    }

    private func row(number: Int?, time: Double) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                title(number: number, time: time)
                Spacer(minLength: 4)
                actions
            }
            VStack(alignment: .leading, spacing: 6) {
                title(number: number, time: time)
                actions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func title(number: Int?, time: Double) -> some View {
        HStack(spacing: 8) {
            Text(markerName(number))
                .font(.system(size: 13, weight: .medium))
            Text(ReviewTime.precise(time))
                .font(Theme.mono())
        }
        .foregroundStyle(Theme.ink)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button(review.isHearingJoin ? "Playing…" : "Hear the join") { endTyping(); review.hearJoin() }
                .disabled(review.isHearingJoin)
                .help("Play a few seconds either side of this marker (H)")
                .accessibilityLabel(review.isHearingJoin ? "Playing…" : "Hear the join")
            Button("−0.1 s") { endTyping(); review.nudgeSelection(by: -0.1) }
                .help("Move the marker earlier (←)")
                .accessibilityLabel("−0.1 s")
            Button("+0.1 s") { endTyping(); review.nudgeSelection(by: 0.1) }
                .help("Move the marker later (→)")
                .accessibilityLabel("+0.1 s")
            Button("Delete", role: .destructive) { endTyping(); review.deleteSelectedMarker() }
                .help("Delete this marker (Delete key)")
                .accessibilityLabel("Delete")
        }
        .buttonStyle(.paperSmall)
    }
}

/// The side's trims, and undo. These wrap onto two rows rather than squeezing.
private struct TrimRow: View {
    @Environment(AppModel.self) private var model

    private var review: ReviewModel { model.reviewModel }

    private var isTrimmed: Bool {
        (review.review?.trimStart ?? 0) > 0 || review.review?.source.trimEnd != nil
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                trims
                undo
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { trims }
                undo
            }
        }
        .buttonStyle(.paperSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var trims: some View {
        Button {
            endTyping()
            review.setTrimStart()
        } label: {
            HStack(spacing: 6) {
                Text("Trim side start")
                KeyLetter("I")
            }
        }
        .help("Keep this whole side from the playhead onward. To trim one track, use Edit.")
        .accessibilityLabel("Trim side start")
        Button {
            endTyping()
            review.setTrimEnd()
        } label: {
            HStack(spacing: 6) {
                Text("Trim side end")
                KeyLetter("O")
            }
        }
        .help("Keep this whole side up to the playhead. To trim one track, use Edit.")
        .accessibilityLabel("Trim side end")
        if isTrimmed {
            Button("Reset") { endTyping(); review.resetTrim() }
                .help("Keep the whole side again")
                .accessibilityLabel("Reset")
        }
    }

    private var undo: some View {
        Button("Undo") { endTyping(); review.undo() }
            .help("Undo a marker or trim change (⌘Z). Redo with ⌘⇧Z.")
            .accessibilityLabel("Undo")
    }
}

/// The tracks that the markers make, with the side's options underneath.
private struct TrackColumn: View {
    @Environment(AppModel.self) private var model

    let tape: ShelfTape
    let size: LayoutSize

    private var review: ReviewModel { model.reviewModel }
    private var tracks: [ReviewTrack] { review.review?.tracks ?? [] }

    private var keptDuration: Double {
        (review.review?.trimEnd ?? 0) - (review.review?.trimStart ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                CapLabel(sideHeading(model.selectedItem))
                Text("Tracks on this side")
                    .font(Theme.serif(size == .regular ? 21 : 17))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(number: index + 1, track: track, size: size)
                    }

                    if keptDuration > 0, keptDuration < review.duration - 0.01 {
                        Text("Keeping \(TimeLabel.clock(keptDuration)) of \(TimeLabel.clock(review.duration))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 10)
                    }
                    Text("Your master stays whole. Nothing is cut until you push to the site.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
            }

            EditSelectedTrack()
                .padding(.vertical, 12)

            if SideOptionsMenu.isOffered(for: tape, item: model.selectedItem) {
                HairlineRule()
                SideOptionsMenu(tape: tape)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 12)
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
}

/// Opens the track under the playhead in Edit, at the same moment.
private struct EditSelectedTrack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let selected = model.reviewModel.handoffTrack {
            let name = selected.track.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Track \(selected.number)"
            let note = "Open “\(name)” at this position to adjust its trim, level or speed."
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    endTyping()
                    model.editSelectedTrack()
                } label: {
                    HStack(spacing: 8) {
                        Text("Edit selected track")
                        Image(systemName: "arrow.right")
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.paperPrimary)
                .accessibilityLabel("Edit selected track")

                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(3)
                    .help(note)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A track in the column. A click goes to it, and a double-click on its name renames
/// it. The name is only a field while it's being typed, so keys otherwise reach Review.
private struct TrackRow: View {
    @Environment(AppModel.self) private var model
    /// The name being typed, or nil when it isn't being edited.
    @State private var draft: String?
    @FocusState private var isFocused: Bool

    let number: Int
    let track: ReviewTrack
    let size: LayoutSize

    private var placeholder: String { "Track \(number)" }

    private var detail: String {
        let start = TimeLabel.clock(track.start)
        return model.reviewModel.review?.source.side.map { "Side \($0) · \(start)" } ?? start
    }

    var body: some View {
        NumberedTrackRow(
            number: trackNumberText(number),
            detail: detail,
            duration: TimeLabel.clock(track.duration),
            size: size,
            isPicked: model.reviewModel.selectedTrack?.id == track.id
        ) {
            name
        }
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded {
            // A click while typing is placing the cursor.
            if draft == nil { go() }
        })
        // Choosing another tab can take the field away before it loses focus.
        .onDisappear { finish(save: true) }
    }

    @ViewBuilder private var name: some View {
        if draft != nil {
            TextField(placeholder, text: Binding(get: { draft ?? "" }, set: { if draft != nil { draft = $0 } }))
                .textFieldStyle(.plain)
                .font(Theme.serif(size.rowName))
                .foregroundStyle(Theme.ink)
                .focused($isFocused)
                .onSubmit {
                    finish(save: true)
                    endTyping()
                }
                .onExitCommand {
                    finish(save: false)
                    endTyping()
                }
                .onChange(of: isFocused) { _, focused in if !focused { finish(save: true) } }
                .onAppear { DispatchQueue.main.async { isFocused = true } }
                .accessibilityLabel("Name of track \(number)")
        } else {
            let shown = track.name.flatMap { $0.isEmpty ? nil : $0 } ?? placeholder
            Text(shown)
                .font(Theme.serif(size.rowName))
                .foregroundStyle(track.name?.isEmpty == false ? Theme.ink : Theme.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture(count: 2) { rename() }
                .help("\(shown). Double-click to rename.")
                .accessibilityLabel("Track \(number), \(shown), at \(TimeLabel.clock(track.start))")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { go() }
                .accessibilityAction(named: "Rename") { rename() }
        }
    }

    private func go() {
        endTyping()
        if let id = track.markerID,
           let marker = model.reviewModel.review?.markers.first(where: { $0.id == id }) {
            model.reviewModel.select(marker)
        } else {
            model.reviewModel.selectedMarkerID = nil
            model.reviewModel.seek(to: track.start)
        }
    }

    private func rename() {
        guard track.trackID != nil else { return }
        draft = track.name ?? ""
    }

    private func finish(save: Bool) {
        guard let name = draft else { return }
        draft = nil
        guard save, let id = track.trackID, name != (track.name ?? "") else { return }
        model.reviewModel.rename(trackID: id, to: name)
    }
}
