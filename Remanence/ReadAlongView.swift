import RemanenceCore
import SwiftUI

/// Follows along with a recording, line by line, with what's known about the tape
/// beside it.
struct ReadAlongView: View {
    @Environment(AppModel.self) private var model
    @State private var readAlong: ReadAlong?
    @State private var isFollowing = true

    let tape: ShelfTape
    @Binding var showsDetails: Bool
    let size: LayoutSize

    private var item: ShelfTape.Item? { model.selectedItem }
    private var sourceID: Int64? { item?.source.id }
    private var segments: [Segment] { readAlong?.segments ?? [] }

    private var currentIndex: Int? {
        segmentIndex(at: model.player.currentTime, in: segments)
    }

    var body: some View {
        HStack(alignment: .top, spacing: size == .regular ? 28 : 16) {
            VStack(alignment: .leading, spacing: 0) {
                transcript
                HairlineRule()
                TransportBar()
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if showsDetails {
                ReadAlongDetails(tape: tape, readAlong: readAlong, size: size)
                    .frame(width: size.rightColumn)
            }
        }
        .padding(.horizontal, 28)
        .background(Theme.paper)
        .task(id: sourceID) { await observe() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsDetails.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help(showsDetails ? "Hide details" : "Show details")
            }
        }
        .sheet(isPresented: Binding(
            get: { model.isComparingTranscripts },
            set: { model.isComparingTranscripts = $0 }
        )) {
            if let readAlong, let candidate = readAlong.candidate, let sourceID {
                CompareView(
                    sourceID: sourceID,
                    segments: readAlong.segments,
                    currentModel: readAlong.transcriptModel,
                    candidate: candidate
                )
            }
        }
    }

    private func observe() async {
        readAlong = nil
        guard let sourceID, let library = model.library else { return }
        do {
            for try await update in library.readAlongUpdates(sourceID: sourceID) {
                readAlong = update
            }
        } catch is CancellationError {
            return
        } catch {
            model.message = "This transcript couldn’t be loaded. \(error.localizedDescription)"
        }
    }

    @ViewBuilder private var transcript: some View {
        if readAlong == nil {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if segments.isEmpty {
            emptyState
        } else {
            lines
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(emptyTitle)
                .font(Theme.serif(size.sectionTitle))
                .foregroundStyle(Theme.ink)
            Text(emptyDetail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        readAlong?.transcriptModel == nil ? "Still listening" : "No words here"
    }

    private var emptyDetail: String {
        readAlong?.transcriptModel == nil
            ? "The transcript will appear here as soon as it’s ready."
            : "Whisper found no speech in this recording. It may be music or silence."
    }

    private var lines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        LineRow(
                            segment: segment,
                            position: position(of: index),
                            size: size,
                            isEditing: model.editingLineID == segment.id,
                            onSeek: {
                                isFollowing = true
                                Task { await model.player.seek(to: segment.startTime) }
                            },
                            onEdit: {
                                model.player.pause()
                                model.editingLineID = segment.id
                            },
                            onFinishEditing: { text in
                                model.editingLineID = nil
                                guard let text, let id = segment.id else { return }
                                Task { await model.updateLine(id: id, text: text) }
                            }
                        )
                        .id(segment.id)
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollPhaseChange { _, phase in
                // Scrolling by hand means looking around, so stop pulling the view back.
                if phase == .interacting { isFollowing = false }
            }
            .onChange(of: currentIndex) { _, index in
                scroll(to: index, proxy: proxy)
            }
            .onChange(of: isFollowing) { _, following in
                if following { scroll(to: currentIndex, proxy: proxy) }
            }
            .onAppear { scroll(to: currentIndex, proxy: proxy, animated: false) }
            .overlay(alignment: .bottom) {
                if !isFollowing && model.player.isPlaying {
                    Button("Follow along", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        isFollowing = true
                    }
                    .buttonStyle(.paperPrimary)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private func scroll(to index: Int?, proxy: ScrollViewProxy, animated: Bool = true) {
        guard isFollowing, model.editingLineID == nil, let index, segments.indices.contains(index) else { return }
        let id = segments[index].id
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func position(of index: Int) -> LineRow.Position {
        guard let currentIndex else { return .upcoming }
        if index == currentIndex { return .current }
        return index < currentIndex ? .past : .upcoming
    }
}

private struct LineRow: View {
    enum Position {
        case past, current, upcoming
    }

    let segment: Segment
    let position: Position
    let size: LayoutSize
    let isEditing: Bool
    let onSeek: () -> Void
    let onEdit: () -> Void
    let onFinishEditing: (String?) -> Void

    @State private var isHovering = false
    @State private var draft = ""
    @State private var selection: TextSelection?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: size == .regular ? 14 : 10) {
                Text(TimeLabel.clock(segment.startTime))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .frame(width: 52, alignment: .trailing)

                if isEditing {
                    editor
                } else {
                    line
                }
            }
            .padding(.horizontal, size == .regular ? 10 : 7)
            .padding(.vertical, size == .regular ? 12 : 9)
            HairlineRule()
        }
        .background(position == .current || isEditing ? Theme.picked : .clear)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onSeek) {
                Text(segment.text)
                    // The current line is marked by its background, not a larger
                    // font, so following along over a long sermon stays calm.
                    .font(Theme.serif(size.rowName))
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Plays from here")
            .accessibilityAddTraits(position == .current ? .isSelected : [])
            .contextMenu {
                Button("Edit line", action: onEdit)
            }

            editButton
                .opacity(isHovering || position == .current ? 1 : 0)
                .help("Edit line")
                .accessibilityLabel("Edit this line")
        }
    }

    /// Words where there's room for them, and a pencil where there isn't.
    @ViewBuilder private var editButton: some View {
        if size == .regular {
            Button("Edit line", action: onEdit)
                .buttonStyle(.paperSmall)
        } else {
            Button("Edit line", systemImage: "pencil", action: onEdit)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .tint(Theme.accent)
        }
    }

    private var textColor: Color {
        switch position {
        case .current: Theme.ink
        // Plain muted is about 5.6 to 1 on paper. Any lighter falls under 4.5 to 1.
        case .past: Theme.muted
        case .upcoming: Theme.ink.opacity(0.72)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Line", text: $draft, selection: $selection, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.serif(size.rowName))
                .foregroundStyle(Theme.ink)
                .padding(8)
                .background(Theme.field, in: .rect(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1)
                }
                .focused($isFocused)
                .onSubmit { onFinishEditing(draft) }
                .onExitCommand { onFinishEditing(nil) }

            HStack {
                Button("Save") { onFinishEditing(draft) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { onFinishEditing(nil) }
            }
            .buttonStyle(.paperSmall)
        }
        .onAppear {
            draft = segment.text
            isFocused = true
            // Start at the end. With the whole line selected, one key would replace it.
            selection = TextSelection(insertionPoint: draft.endIndex)
        }
    }
}

/// The right column: what's known about the tape, and ways to improve it.
private struct ReadAlongDetails: View {
    @Environment(AppModel.self) private var model
    @State private var context = ""
    @FocusState private var isContextFocused: Bool

    let tape: ShelfTape
    let readAlong: ReadAlong?
    let size: LayoutSize

    private var details: SummaryDetails? { readAlong?.track?.summaryDetails }
    private var hasSummary: Bool { readAlong?.track?.summary != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let text = tape.tape.description ?? details?.summaryLong {
                    section("About") {
                        Text(text)
                            .font(Theme.serif(14))
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                }

                if let mentioned = details?.mentioned, !mentioned.isEmpty {
                    section("Mentioned") {
                        FlowLayout(spacing: 6) {
                            ForEach(mentioned, id: \.self) { name in
                                Button {
                                    model.search(for: name)
                                } label: {
                                    Text(name)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .overlay {
                                            Capsule().strokeBorder(Theme.buttonBorder)
                                        }
                                        .contentShape(.capsule)
                                }
                                .buttonStyle(.plain)
                                .help("Search every tape for \(name)")
                            }
                        }
                    }
                }

                section("Tape notes") {
                    TextEditor(text: $context)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        // A fixed height, since a column that scrolls offers no height.
                        .frame(height: 96)
                        .background(Theme.field, in: .rect(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Theme.fieldBorder)
                                .allowsHitTesting(false)
                        }
                        .focused($isContextFocused)
                        .accessibilityLabel("Notes about this tape")
                    hint("Where it came from, who’s speaking, anything a summary should know.")
                    summaryButton
                }

                HairlineRule()

                section("Transcript") {
                    betterTranscript
                }
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, size == .regular ? 24 : 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.line)
                .frame(width: 1)
                .accessibilityHidden(true)
        }
        .onAppear { context = tape.tape.context ?? "" }
        .onChange(of: tape.id) { _, _ in context = tape.tape.context ?? "" }
        .onChange(of: isContextFocused) { _, focused in
            if !focused { saveContext() }
        }
        .onDisappear { saveContext() }
    }

    private func saveContext() {
        guard context != (tape.tape.context ?? "") else { return }
        Task { await model.setContext(tape, context) }
    }

    private var summaryButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(hasSummary ? "Rewrite Summary" : "Write a Summary") {
                saveContext()
                Task { await model.requestSummary(tape) }
            }
            .buttonStyle(.paperStandard)
            .disabled(tape.status.isActive || readAlong?.transcriptModel == nil)

            hint("Summaries are reference for what you write in Site Post. They’re never published by themselves.")
        }
    }

    @ViewBuilder private var betterTranscript: some View {
        if let readAlong {
            let other = Library.comparisonModel(for: readAlong.transcriptModel)
            let canCompare = readAlong.transcriptModel != nil && model.hasModel(other)

            if readAlong.isComparing {
                Label("Listening with the \(other) model…", systemImage: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            } else if readAlong.candidate != nil {
                Button("Compare transcripts…") { model.isComparingTranscripts = true }
                    .buttonStyle(.paperPrimary)
                hint("The new transcript is ready. Nothing changes until you choose.")
            } else {
                Button("Try a Better Transcript") {
                    if let id = model.selectedItem?.source.id {
                        Task { await model.requestComparison(sourceID: id, model: other) }
                    }
                }
                .buttonStyle(.paperStandard)
                .disabled(!canCompare)
                hint("Listens again with the \(other) model. You’ll compare them before anything changes.")
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CapLabel(title)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays out items in rows, wrapping as needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let positions = place(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? positions.width, height: positions.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = place(subviews, width: bounds.width)
        for (subview, point) in zip(subviews, positions.points) {
            subview.place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: fitting(subview, in: bounds.width)
            )
        }
    }

    /// An item's own size, unless that's wider than a whole row.
    private func fitting(_ subview: LayoutSubview, in width: CGFloat) -> ProposedViewSize {
        subview.sizeThatFits(.unspecified).width > width
            ? ProposedViewSize(width: width, height: nil)
            : .unspecified
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(fitting(subview, in: width))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, widest, y + rowHeight)
    }
}

/// Compares the current transcript with a new one, change by change.
struct CompareView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var changes: [TranscriptChange]?
    @State private var confirmingReplace = false

    let sourceID: Int64
    let segments: [Segment]
    let currentModel: String?
    let candidate: TranscriptCandidate

    private var editedCount: Int { segments.filter(\.edited).count }

    private var currentName: String { "Current (\(currentModel ?? "unknown"))" }
    private var candidateName: String { candidate.model.capitalized }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Which sounds right?")
                    .font(Theme.display(30))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .foregroundStyle(Theme.muted)
            }
            .padding(24)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(changes ?? []) { change in
                        ChangeRow(
                            change: change,
                            currentName: currentName,
                            candidateName: candidateName
                        )
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if changes == nil { ProgressView() }
            }

            Divider()

            HStack {
                if editedCount > 0 {
                    Text(editedCount == 1 ? "Using the new one replaces your 1 corrected line." : "Using the new one replaces your \(editedCount) corrected lines.")
                        .font(.callout)
                        .foregroundStyle(Theme.attention)
                }
                Spacer()
                Button("Decide Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Keep Current") {
                    dismiss()
                    Task { await model.keepCurrentTranscript(sourceID: sourceID) }
                }
                Button("Use \(candidateName)") {
                    if editedCount > 0 {
                        confirmingReplace = true
                    } else {
                        adopt()
                    }
                }
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 480, idealHeight: 620)
        .background(Theme.paper)
        .task {
            let current = segments
            let lines = candidate.lines
            changes = await Task.detached(priority: .userInitiated) {
                TranscriptComparison.changes(current: current, candidate: lines)
            }.value
        }
        .confirmationDialog(
            "Replace your corrections?",
            isPresented: $confirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Use \(candidateName) Anyway", role: .destructive) { adopt() }
        } message: {
            Text("The new transcript doesn’t include the lines you corrected by hand.")
        }
    }

    private func adopt() {
        dismiss()
        Task { await model.useCandidate(sourceID: sourceID) }
    }

    private var subtitle: String {
        guard let changes else { return "Comparing…" }
        switch changes.count {
        case 0: return "These two transcripts match word for word."
        case 1: return "They differ in 1 place. Play it to hear which is right."
        default: return "They differ in \(changes.count) places. Play any of them to hear which is right."
        }
    }
}

private struct ChangeRow: View {
    @Environment(AppModel.self) private var model

    let change: TranscriptChange
    let currentName: String
    let candidateName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                Task {
                    await model.player.seek(to: max(0, change.time - 1))
                    model.player.play()
                }
            } label: {
                Label(TimeLabel.clock(change.time), systemImage: "play.fill")
                    .font(.system(size: 11, design: .monospaced))
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Play from \(TimeLabel.clock(change.time))")

            VStack(alignment: .leading, spacing: 8) {
                version(currentName, change.current)
                version(candidateName, change.candidate)
            }
        }
    }

    private func version(_ name: String, _ changed: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            Text(sentence(changed))
                .font(Theme.serif(15))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inset, in: .rect(cornerRadius: 6))
    }

    private func sentence(_ changed: String) -> AttributedString {
        var result = AttributedString(change.before.isEmpty ? "" : change.before + " ")
        var middle = AttributedString(changed.isEmpty ? "(nothing)" : changed)
        middle.backgroundColor = Color(red: 0.902, green: 0.812, blue: 0.624)
        result += middle
        if !change.after.isEmpty { result += AttributedString(" " + change.after) }
        return result
    }
}
