import RemanenceCore
import SwiftUI

/// Where you mark what's on a tape: scrub the waveform, place markers, name tracks.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var showsTracks = true

    let tape: ShelfTape

    private var review: ReviewModel { model.reviewModel }
    private var sourceID: Int64? { model.selectedItem?.source.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 12)

            if review.review != nil, let waveform = review.waveform {
                VStack(alignment: .leading, spacing: 10) {
                    OverviewStrip(waveform: waveform)
                        .frame(height: 58)
                    ZoomedWaveform(waveform: waveform)
                        .frame(minHeight: 170, maxHeight: .infinity)
                    controls
                    MarkerControls()
                    KeyHints()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            } else {
                preparing
            }
        }
        .background(Theme.paper)
        .task(id: sourceID) {
            if let sourceID { await review.observe(sourceID: sourceID) }
        }
        .inspector(isPresented: $showsTracks) {
            TrackList()
                .inspectorColumnWidth(min: 220, ideal: 250, max: 340)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                model.leaveReview()
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

            if tape.items.count > 1 {
                Picker("Recording", selection: Binding(
                    get: { model.selectedItemIndex },
                    set: { model.choose(itemAt: $0) }
                )) {
                    ForEach(Array(tape.items.enumerated()), id: \.element.id) { index, item in
                        Text(item.name).tag(index)
                    }
                }
                .frame(maxWidth: 320)
            }
        }
    }

    private var preparing: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Reading the waveform…")
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                review.togglePlayback()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 40, height: 40)
                    .background(Theme.ink, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.player.isPlaying ? "Pause" : "Play")

            PlayheadClock()

            Spacer(minLength: 4)

            Button {
                review.addMarkerAtPlayhead()
            } label: {
                Label("Add Marker", systemImage: "flag.fill")
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent)

            Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                review.setZoom(span: review.zoomSpan * 1.5, keeping: model.player.preciseTime)
            }
            .labelStyle(.iconOnly)
            Button("Zoom In", systemImage: "plus.magnifyingglass") {
                review.setZoom(span: review.zoomSpan / 1.5, keeping: model.player.preciseTime)
            }
            .labelStyle(.iconOnly)
        }
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
            Text(ReviewTime.precise(model.player.preciseTime))
                .font(.system(size: 17, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
                .frame(minWidth: 112, alignment: .leading)
                .accessibilityLabel("Position \(TimeLabel.clock(model.player.preciseTime))")
        }
    }
}

enum ReviewTime {
    /// `12:04.3`, with tenths for placing markers.
    static func precise(_ seconds: Double) -> String {
        // Rounded, so a marker nudged to 1234.0 can't read as 20:33.9 from float error.
        let tenths = Int((max(0, seconds) * 10).rounded())
        let minutes = tenths / 600
        let remainder = (tenths % 600) / 10
        let hours = minutes / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d.%d", hours, minutes % 60, remainder, tenths % 10)
            : String(format: "%d:%02d.%d", minutes, remainder, tenths % 10)
    }
}

private enum WaveformColors {
    static let kept = Color(red: 0.42, green: 0.384, blue: 0.337)
    static let trimmed = Color(red: 0.827, green: 0.788, blue: 0.69)
    static let playhead = Color(red: 0.659, green: 0.196, blue: 0.102)
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
            let duration = max(review.duration, 0.001)
            let trimStart = review.review?.trimStart ?? 0
            let trimEnd = review.review?.trimEnd ?? duration

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let columns = max(1, Int(size.width / 2))
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
                        width: max(4, width * review.zoomSpan / duration),
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
        .background(Theme.card.opacity(0.7), in: .rect(cornerRadius: 6))
        .clipShape(.rect(cornerRadius: 6))
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

/// A close-up for placing markers. Drag to scrub, pinch to zoom.
private struct ZoomedWaveform: View {
    @Environment(AppModel.self) private var model
    @State private var pinchStartSpan: Double?

    let waveform: Waveform

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
                    let columns = max(1, Int(size.width / 2))
                    let levels = waveform.levels(from: start, to: start + span, columns: columns)
                    drawLevels(levels, in: CGSize(width: size.width, height: size.height - 22), context: context) { index in
                        let time = start + span * (Double(index) + 0.5) / Double(columns)
                        return time >= trimStart && time <= trimEnd ? WaveformColors.kept : WaveformColors.trimmed
                    }
                }
                .padding(.top, 22)

                TimeRuler(start: start, span: span, width: width)
                    .allowsHitTesting(false)

                PlayheadLine(duration: review.duration, start: start, span: span, width: width, height: height)

                ForEach(review.review?.markers ?? []) { marker in
                    let x = width * (marker.time - start) / span
                    if x >= -40, x <= width + 40 {
                        MarkerFlag(marker: marker, width: width, span: span, height: height)
                            .offset(x: x)
                    }
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
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
        .background(Theme.card, in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
    }
}

struct TimeRuler: View {
    let start: Double
    let span: Double
    let width: CGFloat

    private var step: Double {
        let target = span / max(1, Double(width) / 90)
        return [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600].first { $0 >= target } ?? 7200
    }

    var body: some View {
        let first = (start / step).rounded(.up) * step
        let marks = Array(stride(from: first, through: start + span, by: step))
        ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { time in
                Text(TimeLabel.clock(time))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize()
                    .offset(x: width * (time - start) / span + 3, y: 4)
            }
        }
    }
}

/// A draggable marker with a flag showing its time.
private struct MarkerFlag: View {
    @Environment(AppModel.self) private var model
    @State private var dragTime: Double?

    let marker: Marker
    let width: CGFloat
    let span: Double
    let height: CGFloat

    private var isSelected: Bool { model.reviewModel.selectedMarkerID == marker.id }

    var body: some View {
        let color = isSelected ? WaveformColors.selected : Theme.ink
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color)
                .frame(width: 2, height: height)
            Text(TimeLabel.clock(dragTime ?? marker.time))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.paper)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color, in: .rect(cornerRadius: 3))
                .fixedSize()
        }
        .offset(x: dragTime.map { width * ($0 - marker.time) / span } ?? 0)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
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
            TapGesture().onEnded { model.reviewModel.select(marker) }
        )
        .accessibilityElement()
        .accessibilityLabel("Marker at \(TimeLabel.clock(marker.time))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.reviewModel.select(marker) }
    }
}

/// Actions for the selected marker, and the trims. These wrap onto two rows rather
/// than squeezing, so nothing ever stacks letter by letter in a narrow window.
private struct MarkerControls: View {
    @Environment(AppModel.self) private var model

    private var review: ReviewModel { model.reviewModel }

    var body: some View {
        @Bindable var review = review

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let marker = review.selectedMarker {
                    Text("Marker at \(ReviewTime.precise(marker.time))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize()
                    Button(review.isHearingJoin ? "Playing…" : "Hear the Join") { review.hearJoin() }
                        .disabled(review.isHearingJoin)
                        .fixedSize()
                    Button("−0.1") { review.nudgeSelection(by: -0.1) }.fixedSize()
                    Button("+0.1") { review.nudgeSelection(by: 0.1) }.fixedSize()
                    Button("Delete", role: .destructive) { review.deleteSelectedMarker() }.fixedSize()
                } else {
                    Text("Press M to mark where a track starts.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 24)

            HStack(spacing: 8) {
                Toggle("Snap to quiet", isOn: $review.snapsToQuiet)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("New markers settle into the nearest quiet moment. Hold Option to place one exactly.")
                Spacer(minLength: 4)
                Button("Trim Side Start") { review.setTrimStart() }.fixedSize()
                    .help("Keep this whole side from the playhead onward. To trim one track, use Edit.")
                Button("Trim Side End") { review.setTrimEnd() }.fixedSize()
                    .help("Keep this whole side up to the playhead. To trim one track, use Edit.")
                if (review.review?.trimStart ?? 0) > 0 || review.review?.source.trimEnd != nil {
                    Button("Reset") { review.resetTrim() }.fixedSize()
                }
            }
        }
        .controlSize(.small)
    }
}

/// Shows as many key reminders as fit, most useful first.
private struct KeyHints: View {
    private static let all: [(String, String)] = [
        ("Space", "Play"), ("M", "Marker"), ("H", "Hear join"), ("← →", "Nudge"),
        (", .", "Previous, next"), ("J K L", "Shuttle"), ("- =", "Zoom"), ("I O", "Trim"), ("⌘Z", "Undo"),
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(Self.all)
            row(Array(Self.all.prefix(6)))
            row(Array(Self.all.prefix(4)))
            row(Array(Self.all.prefix(2)))
            EmptyView()
        }
    }

    private func row(_ hints: [(String, String)]) -> some View {
        HStack(spacing: 10) {
            ForEach(hints, id: \.0) { key, label in
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

/// The tracks that the markers make. Names are edited in place.
private struct TrackList: View {
    @Environment(AppModel.self) private var model

    private var review: ReviewModel { model.reviewModel }
    private var tracks: [ReviewTrack] { review.review?.tracks ?? [] }

    private var keptDuration: Double {
        (review.review?.trimEnd ?? 0) - (review.review?.trimStart ?? 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(tracks.count == 1 ? "1 track" : "\(tracks.count) tracks")
                    .font(Theme.display(24))
                    .foregroundStyle(Theme.ink)
                Text("Your master stays whole. Nothing is cut until you push to the site.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.bottom, 8)

                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(number: index + 1, track: track)
                }

                if keptDuration > 0, keptDuration < review.duration - 0.01 {
                    Text("Keeping \(TimeLabel.clock(keptDuration)) of \(TimeLabel.clock(review.duration))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkMuted)
                        .padding(.top, 8)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.paper.opacity(0.6))
    }
}

private struct TrackRow: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @FocusState private var isFocused: Bool

    let number: Int
    let track: ReviewTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(number)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                TextField("Track \(number)", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .focused($isFocused)
                    .onSubmit(save)
                    .accessibilityLabel("Name of track \(number)")
            }
            HStack(spacing: 8) {
                Button(TimeLabel.clock(track.start)) {
                    if let id = track.markerID,
                       let marker = model.reviewModel.review?.markers.first(where: { $0.id == id }) {
                        model.reviewModel.select(marker)
                    } else {
                        model.reviewModel.selectedMarkerID = nil
                        model.reviewModel.seek(to: track.start)
                    }
                }
                .buttonStyle(.borderless)
                .tint(Theme.accent)
                .accessibilityLabel("Go to track \(number), at \(TimeLabel.clock(track.start))")

                Text("· \(TimeLabel.clock(track.duration)) long")
                    .foregroundStyle(Theme.inkMuted)
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Theme.card : .clear, in: .rect(cornerRadius: 6))
        .onAppear { name = track.name ?? "" }
        .onChange(of: track.name) { _, updated in
            if !isFocused { name = updated ?? "" }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { save() }
        }
    }

    private var isCurrent: Bool {
        let time = model.player.currentTime
        return time >= track.start && time < track.end
    }

    private func save() {
        guard let id = track.trackID, name != (track.name ?? "") else { return }
        model.reviewModel.rename(trackID: id, to: name)
    }
}
