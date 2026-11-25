import RemanenceCore
import SwiftUI

/// Where a tape gets recorded: the meter and what to do next on the left, the tape's
/// label and settings on the right. The meter can fill the window so it reads from
/// across the room at the tape machine.
struct RecordView: View {
    @Environment(AppModel.self) private var model
    @State private var size = LayoutSize.compact

    private var record: RecordModel { model.recordModel }

    /// The side being recorded or just recorded. A new tape starts at A, whatever the
    /// last tape got to.
    private var side: String {
        record.recordingTapeID == nil ? "A" : record.currentSide
    }

    private var footerNote: String {
        [record.catalogNumber, "Side \(side)"].compactMap(\.self).joined(separator: " · ")
    }

    var body: some View {
        Group {
            if record.permissionDenied {
                permissionNeeded
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    RecordHeader(side: side, size: size)

                    HStack(alignment: .top, spacing: size == .regular ? 28 : 18) {
                        RecordStage(size: size)
                        if !record.isLarge {
                            TapeColumn(size: size)
                                .frame(width: size.rightColumn)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            record.toggleLarge()
                        } label: {
                            Label(
                                record.isLarge ? "Show Setup" : "Large Meter",
                                systemImage: record.isLarge ? "sidebar.trailing" : "arrow.up.left.and.arrow.down.right"
                            )
                            .labelStyle(.titleAndIcon)
                        }
                        .help(record.isLarge ? "Show the tape’s label and settings" : "Fill the window with the meter, to read it from across the room")
                    }
                }
            }
        }
        .background(Theme.paper)
        .onGeometryChange(for: LayoutSize.self) { geometry in
            LayoutSize(detailWidth: geometry.size.width)
        } action: {
            size = $0
        }
        .onChange(of: footerNote, initial: true) { _, note in model.footerNote = note }
        .task { await record.open() }
        .onDisappear { record.close() }
    }

    private var permissionNeeded: some View {
        VStack(spacing: 10) {
            Text("Remanence needs the microphone permission")
                .font(Theme.display(28))
                .foregroundStyle(Theme.ink)
            Text("macOS treats every audio input as a microphone, including your interface. Audio stays on this Mac.")
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
            Button("Open Privacy Settings") { record.openPrivacySettings() }
                .buttonStyle(.paperPrimary)
                .padding(.top, 6)
            Button("Check Again") { Task { await record.open() } }
                .buttonStyle(.paperStandard)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The collection the tape on this screen is in, or is about to go in.
private struct TapeCollectionName {
    /// Nil for a collection that hasn't been made yet.
    let id: Int64?
    let name: String

    @MainActor
    init?(in model: AppModel) {
        let record = model.recordModel
        if let tapeID = record.recordingTapeID {
            // Once the tape exists, only what it's really in counts.
            guard let tape = model.shelf.first(where: { $0.id == tapeID }),
                  let collection = model.collection(of: tape) else { return nil }
            id = collection.id
            name = collection.collection.name
        } else if record.collectionChoice == RecordModel.newCollection {
            let typed = record.newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { return nil }
            id = nil
            name = typed
        } else {
            guard let collection = model.collections.first(where: { $0.id == record.collectionChoice }) else { return nil }
            id = collection.id
            name = collection.collection.name
        }
    }
}

/// A collection's name, which opens the collection once there is one.
private struct CollectionLink: View {
    @Environment(AppModel.self) private var model

    let collection: TapeCollectionName

    var body: some View {
        if let id = collection.id {
            Button {
                model.sidebarSelection = .collection(id)
            } label: {
                Text(collection.name)
                    .underline()
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open \(collection.name)")
        } else {
            Text(collection.name)
                .lineLimit(1)
                .help(collection.name)
        }
    }
}

/// What's happening, to which tape. With the large meter, the number to write on the
/// box sits here too, since the right column is hidden.
private struct RecordHeader: View {
    @Environment(AppModel.self) private var model

    let side: String
    let size: LayoutSize

    private var record: RecordModel { model.recordModel }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                EyebrowLabel(["Capture", record.catalogNumber].compactMap(\.self).joined(separator: " / "))
                Text(title)
                    .font(Theme.serif(size.pageTitle))
                    .tracking(size == .regular ? -1.9 : -1)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .help(title)
                    .accessibilityAddTraits(.isHeader)
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if record.isLarge, let number = record.catalogNumber {
                largeNumber(number)
            }
        }
    }

    private var title: String {
        switch record.stage {
        case .setup: "Record a tape"
        case .checking: "Checking levels"
        case .recording: "Recording Side \(side)"
        case .finished: record.savedNothing ? "Nothing was saved" : "Side \(side) saved"
        }
    }

    /// What the tape is called: its own name once it exists, or what's been typed.
    private var name: String? {
        if let tapeID = record.recordingTapeID {
            return model.shelf.first { $0.id == tapeID }?.tape.title
        }
        let typed = record.tapeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? nil : typed
    }

    private var subtitle: some View {
        let name = name
        let collection = TapeCollectionName(in: model)
        return HStack(spacing: 8) {
            if let name {
                Text(name)
                    .lineLimit(1)
                    .help(name)
            }
            if name != nil, collection != nil {
                Text("·")
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            if let collection {
                CollectionLink(collection: collection)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(Theme.muted)
        .frame(minHeight: 18)
    }

    private func largeNumber(_ number: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(number)
                .font(.system(size: 46, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize()
            Text(record.recordingTapeID != nil ? "Write this number on the box." : "This tape’s number, given when you press Record.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

extension RecordModel {
    /// Whether the pass that just ended left nothing behind. The clock alone isn't
    /// enough, because an input restarting afterward sets it back to zero.
    fileprivate var savedNothing: Bool {
        stage == .finished && clock == 0 && lastRecordedSourceID == nil
    }
}

/// The meter, what it means, and what to do next.
private struct RecordStage: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingReRecord = false
    /// The last moments of input. Kept here so it survives the layout changing around
    /// it, and stays on screen after Stop.
    @State private var history: [Float] = []

    let size: LayoutSize

    private var record: RecordModel { model.recordModel }

    var body: some View {
        // Scrolls only when the window is too short for all of it.
        ViewThatFits(in: .vertical) {
            column
            ScrollView { column }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { historySampler }
        .onChange(of: record.stage) { _, stage in
            if stage == .recording { history = [] }
        }
        .confirmationDialog(
            "Record side \(record.currentSide) again?",
            isPresented: $confirmingReRecord,
            titleVisibility: .visible
        ) {
            Button("Re-record Side \(record.currentSide)", role: .destructive) {
                Task { await record.reRecordLastSide() }
            }
        } message: {
            Text("The take you just made moves to the Trash, and recording starts again right away. Rewind the tape first.")
        }
    }

    /// The meter takes whatever height the words and buttons leave. Everything under
    /// it is ordered so that what matters most is nearest.
    private var column: some View {
        VStack(alignment: .leading, spacing: 10) {
            MeterPanel(size: size)

            if record.isRecording || record.stage == .finished {
                inputHistory
            }

            switch record.stage {
            case .setup:
                setupButtons
                advice
            case .checking:
                Button("Cancel") { record.cancelLevelCheck() }
                    .buttonStyle(.paperStandard)
                advice
            case .recording:
                recordingButtons
                advice
            case .finished:
                afterStop
            }

            warnings
        }
    }

    // MARK: Input history

    private var inputHistory: some View {
        // The question about the tape ending takes the history's place, so the buttons
        // and the advice under it don't move out of view.
        let asking = record.askingIfFinished
        return ZStack {
            VStack(alignment: .leading, spacing: 6) {
                // The large meter needs the height more than the strip needs a name.
                if !record.isLarge {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Input history")
                            .font(Theme.serif(size == .regular ? 21 : 16))
                            .foregroundStyle(Theme.ink)
                            .fixedSize()
                        Spacer(minLength: 0)
                        Text("Last 12 seconds")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.muted)
                            .fixedSize()
                    }
                }
                LiveStrip(levels: history)
                    .frame(height: size == .regular ? 68 : record.isLarge ? 28 : 40)
            }
            .opacity(asking ? 0 : 1)
            .accessibilityHidden(asking)

            if asking {
                tapeEndQuestion
            }
        }
    }

    @ViewBuilder private var historySampler: some View {
        if record.isRecording {
            TimelineView(.animation(minimumInterval: 1.0 / 10)) { timeline in
                Color.clear
                    .onChange(of: timeline.date) { _, _ in
                        // -70 dB to 0 dB, the same scale as the review waveform.
                        let level = Float(max(0, min(1, (record.capture.snapshot.peak + 70) / 70)))
                        history.append(level)
                        if history.count > LiveStrip.length { history.removeFirst() }
                    }
            }
            .accessibilityHidden(true)
        }
    }

    private var tapeEndQuestion: some View {
        let question = Text("Tape finished?")
            .font(Theme.display(record.isLarge ? 28 : 20))
            .foregroundStyle(Theme.ink)
            .fixedSize()
        let answers = HStack(spacing: 9) {
            Button("Yes, Stop Recording") { Task { await record.tapeFinishedConfirmed() } }
                .buttonStyle(.paperPrimary)
            Button("Keep Recording") { record.keepRecording() }
                .buttonStyle(.paperStandard)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                question
                answers
            }
            VStack(spacing: 6) {
                question
                answers
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Theme.hero, in: .rect(cornerRadius: 8))
    }

    // MARK: Buttons

    private var setupButtons: some View {
        HStack(spacing: 9) {
            Button {
                Task { await record.startRecording() }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.paperPrimary)
            .disabled(!record.isListening)

            Button("Check Levels") { record.startLevelCheck() }
                .buttonStyle(.paperStandard)
                .disabled(!record.isListening)
        }
    }

    private var recordingButtons: some View {
        let count = record.markerTimes.count
        return HStack(spacing: 9) {
            Button {
                Task { await record.stopRecording() }
            } label: {
                Label("Stop Side \(record.currentSide)", systemImage: "stop.fill")
            }
            .buttonStyle(.paperPrimary)

            Button {
                record.addMarker()
            } label: {
                Label("Add marker", systemImage: "flag.fill")
            }
            .buttonStyle(.paperStandard)

            Spacer(minLength: 0)

            if count > 0 {
                Text(count == 1 ? "1 marker" : "\(count) markers")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
            }
        }
    }

    /// The next steps, in place of the buttons that were there while recording.
    private var afterStop: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(record.savedNothing
                 ? "No audio arrived, so nothing was saved from this pass."
                 : record.isFinishing ? "Saving…" : "Transcribing in the background.")
                .font(.system(size: record.isLarge ? 18 : 13))
                .foregroundStyle(Theme.muted)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    reviewButton
                    nextSideButton
                    reRecordButton
                    leaveButtons
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 9) {
                        reviewButton
                        nextSideButton
                        reRecordButton
                    }
                    HStack(spacing: 9) { leaveButtons }
                }
                // For the smallest window.
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 9) {
                        reviewButton
                        nextSideButton
                    }
                    HStack(spacing: 9) {
                        reRecordButton
                        leaveButtons
                    }
                }
            }
        }
    }

    private var reviewButton: some View {
        Button(record.savedNothing ? "Review" : "Review Side \(record.currentSide)") { review() }
            .buttonStyle(.paperPrimary)
            // A tape whose only pass saved nothing is gone, so there's nothing to open.
            // Until the side is saved, its id isn't known yet.
            .disabled(record.isFinishing || !model.shelf.contains { $0.id == record.recordingTapeID })
    }

    private var nextSideButton: some View {
        // Until the side is saved, the next letter is still the one just recorded.
        Button(record.isFinishing ? "Record Next Side" : "Record Side \(record.nextSide)") {
            Task { await record.recordNextSide() }
        }
        .buttonStyle(.paperStandard)
        // A tape whose only pass saved nothing is gone, so it has no next side.
        .disabled(record.isFinishing || !record.isListening || !model.shelf.contains { $0.id == record.recordingTapeID })
    }

    @ViewBuilder private var reRecordButton: some View {
        if record.lastRecordedSourceID != nil {
            Button("Re-record Side \(record.currentSide)…") { confirmingReRecord = true }
                .buttonStyle(.paperStandard)
                .disabled(!record.isListening)
        }
    }

    @ViewBuilder private var leaveButtons: some View {
        Button("New Tape") { record.startAnotherTape() }
            .buttonStyle(.paperStandard)
            // Saving would otherwise write the old tape's side back over the reset.
            .disabled(record.isFinishing)
        Button("Shelf") {
            record.close()
            model.leaveRecording()
        }
        .buttonStyle(.paperStandard)
        .disabled(record.isFinishing)
    }

    /// Opens Review on the recording just made, not the tape's first one.
    private func review() {
        // Read first, because leaving the recorder lets go of it.
        let sourceID = record.lastRecordedSourceID
        record.reviewRecording()
        guard model.route == .review,
              let index = model.selectedTape?.items.firstIndex(where: { $0.source.id == sourceID }),
              index != model.selectedItemIndex else { return }
        model.choose(itemAt: index)
    }

    // MARK: What it means

    private var advice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(adviceHeading)
                .font(Theme.display(record.isLarge ? (size == .regular ? 54 : 44) : size.sectionTitle))
                .foregroundStyle(adviceColor)
            Text(adviceDetail)
                .font(.system(size: record.isLarge ? 18 : 13))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
    }

    private var adviceHeading: String {
        switch record.stage {
        case .checking: return "Play the loudest part of the tape"
        case .setup where record.checkResult != nil: return "Level check finished"
        case .setup, .recording, .finished: return levelTitle
        }
    }

    private var levelTitle: String {
        switch record.advice {
        case .noSignal: "No signal"
        case .tooQuiet: "Too quiet"
        case .fine: "A little low"
        case .good: "Levels look good"
        case .hot: "A little hot"
        case .clipping: "Clipping"
        }
    }

    private var adviceDetail: String {
        switch record.stage {
        case .checking(let left):
            return "Listening for \(left) more seconds. Nothing is being saved."
        case .setup:
            if let result = record.checkResult { return result }
            if !record.knobNote.isEmpty { return "Last time: \(record.knobNote)" }
            if record.isListening { return "Check your levels, or press Record and then play the tape." }
            // The reason it isn't listening has its own line underneath.
            return record.inputProblem == nil ? "Getting the input ready…" : "The input isn’t listening."
        case .recording, .finished:
            switch record.advice {
            case .noSignal: return "Still recording. Press play on the tape machine."
            case .tooQuiet: return "Stop and turn the machine’s output up, then start again."
            case .fine: return "Usable. It can be brought up afterward without harm."
            case .good: return "Leave everything as it is."
            case .hot: return "Turn the machine’s output down slightly."
            case .clipping: return "Stop, turn the output down and start again. This part is damaged."
            }
        }
    }

    private var adviceColor: Color {
        switch record.advice {
        case .good: Theme.goodText
        case .clipping, .tooQuiet: Theme.attention
        case .hot: Theme.accent
        case .noSignal, .fine: Theme.ink
        }
    }

    private var warningLines: [String] {
        var lines: [String] = []
        if let problem = record.inputProblem { lines.append(problem) }
        if record.dropouts > 0 {
            lines.append(record.dropouts == 1
                         ? "1 dropout detected. Listen to this recording afterward."
                         : "\(record.dropouts) dropouts detected. Listen to this recording afterward.")
        }
        if record.audioStalled {
            lines.append("No audio is arriving from this input. Check your interface and cable.")
        }
        if let warning = record.diskWarning { lines.append(warning) }
        return lines
    }

    @ViewBuilder private var warnings: some View {
        let lines = warningLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: record.isLarge ? 18 : 13))
                        .foregroundStyle(Theme.attention)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The tape's label and settings. The settings can be changed except while
/// recording, when they're only shown.
private struct TapeColumn: View {
    @Environment(AppModel.self) private var model

    let size: LayoutSize

    private var record: RecordModel { model.recordModel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                label
                rule
                // Changing the input while a side saves would reset the clock it shows.
                if record.isRecording || record.isFinishing {
                    summary
                } else {
                    RecordSetup(size: size)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, size == .regular ? 24 : 16)
            .padding(.trailing, 4)
            .padding(.bottom, 8)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.line)
                .frame(width: 1)
                .accessibilityHidden(true)
        }
    }

    private var rule: some View {
        HairlineRule()
            .padding(.vertical, 18)
    }

    /// The RA number to write on the box.
    private var label: some View {
        let isAssigned = record.recordingTapeID != nil
        let number = record.catalogNumber
        return VStack(alignment: .leading, spacing: 8) {
            CapLabel("Tape label")
            if let number {
                Text(number)
                    .font(.system(size: size == .regular ? 40 : 32, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
            }
            Text(isAssigned
                 ? "Write this number on the box."
                 : number.map { "This tape will be \($0). It’s given when you press Record." }
                    ?? "The tape’s number is given when you press Record.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnTitle("Capture settings", size: size)
                .padding(.bottom, 4)
            KeyValueRow(key: "Machine", value: record.selectedMachine?.name ?? "None")
            KeyValueRow(key: "Tape speed", value: record.selectedSpeed ?? "Unknown")
            KeyValueRow(key: "Input", value: record.selectedDevice?.name ?? "None")
            KeyValueRow(key: "Channels", value: channels)

            columnTitle("Machine note", size: size)
                .padding(.top, 22)
                .padding(.bottom, 8)
            Text(record.knobNote.isEmpty ? "No note for this machine." : record.knobNote)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)

            rule
            CapLabel("Collection")
                .padding(.bottom, 8)
            Group {
                if let collection = TapeCollectionName(in: model) {
                    CollectionLink(collection: collection)
                } else {
                    Text("None")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
        }
    }

    private var channels: String {
        (record.selectedDevice?.channels ?? 1) > 1 ? record.channelMode.label : "Mono"
    }
}

@MainActor
private func columnTitle(_ title: String, size: LayoutSize) -> some View {
    Text(title)
        .font(Theme.serif(size == .regular ? 21 : 17))
        .foregroundStyle(Theme.ink)
        .lineLimit(1)
        .accessibilityAddTraits(.isHeader)
}

/// Choosing the machine, speed, name, input and collection.
private struct RecordSetup: View {
    @Environment(AppModel.self) private var model

    let size: LayoutSize

    private var record: RecordModel { model.recordModel }

    var body: some View {
        @Bindable var record = record

        VStack(alignment: .leading, spacing: 16) {
            columnTitle("Capture settings", size: size)

            section("Machine") {
                VStack(spacing: 4) {
                    ForEach(record.machines) { machine in
                        let isSelected = machine.id == record.selectedMachineID
                        Button {
                            record.selectMachine(machine)
                        } label: {
                            Text(machine.name)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 28)
                                .foregroundStyle(isSelected ? Theme.primaryText : Theme.ink)
                                .background(isSelected ? Theme.primary : Theme.inset, in: .rect(cornerRadius: 6))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(machine.name)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }

            section("Tape speed") {
                Picker("Tape speed", selection: $record.selectedSpeed) {
                    ForEach(record.selectedMachine?.speedOptions ?? [], id: \.self) { speed in
                        Text(speed).tag(String?.some(speed))
                    }
                    Text("Unknown").tag(String?.none)
                }
                .labelsHidden()
            }

            section("Name (optional)") {
                TextField("What’s written on the box?", text: $record.tapeName)
                    .paperField()
            }

            section("Input") {
                Picker("Device", selection: Binding(
                    get: { record.selectedDevice?.uid },
                    set: {
                        record.selectedDeviceUID = $0
                        record.inputChanged()
                    }
                )) {
                    ForEach(record.devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .labelsHidden()
            }

            if (record.selectedDevice?.channels ?? 1) > 1 {
                section("Channels") {
                    Picker("Channels", selection: Binding(
                        get: { record.channelMode },
                        set: {
                            record.channelMode = $0
                            record.inputChanged()
                        }
                    )) {
                        ForEach(ChannelMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
            }

            HairlineRule()

            section("Machine note") {
                TextField("Output knob at about 6", text: $record.knobNote)
                    .paperField()
                    .onSubmit { record.saveMachineSettings() }
                Text("This appears next time you choose this machine.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }

            HairlineRule()

            section("Collection (optional)") {
                Picker("Collection", selection: $record.collectionChoice) {
                    Text("None").tag(Int64?.none)
                    if !model.collections.isEmpty { Divider() }
                    ForEach(model.collections) { collection in
                        Text(collection.collection.name).tag(Int64?.some(collection.id))
                    }
                    Divider()
                    Text("New Collection…").tag(Int64?.some(RecordModel.newCollection))
                }
                .labelsHidden()
                if record.collectionChoice == RecordModel.newCollection {
                    TextField("Name of the collection", text: $record.newCollectionName)
                        .paperField()
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CapLabel(title)
            content()
        }
    }
}

/// The dark panel: what stage this is, the format, the clock, an analog-style needle,
/// and a peak light that stays lit long enough to notice.
private struct MeterPanel: View {
    @Environment(AppModel.self) private var model

    @State private var meterWidth: CGFloat = 0

    let size: LayoutSize

    private var record: RecordModel { model.recordModel }
    private var isLarge: Bool { record.isLarge }

    private var clockSize: CGFloat {
        switch size {
        case .regular: isLarge ? 96 : 56
        case .compact: isLarge ? 72 : 44
        }
    }

    /// No taller than the scale needs at this width, so the panel has no gap in it.
    /// The large meter has no limit beyond that.
    private var tallestMeter: CGFloat {
        let full = meterWidth * VUMeter.shape.height / VUMeter.shape.width
        let limit: CGFloat = isLarge ? .infinity : size == .regular ? 220 : 170
        return max(48, min(full, limit))
    }

    /// The clock only counts a pass, so it reads zero until one starts.
    private var clock: String {
        let counting = record.isRecording || record.stage == .finished
        return TimeText.timecode(counting ? record.clock : 0)
    }

    var body: some View {
        VStack(spacing: 6) {
            top

            Text(clock)
                .font(.system(size: clockSize, design: .monospaced).monospacedDigit())
                .tracking(isLarge ? -4 : -2)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .layoutPriority(1)
                .accessibilityLabel("Recording time \(clock)")

            VUMeter(capture: record.capture)
                .frame(minHeight: 48, idealHeight: 48, maxHeight: tallestMeter)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { meterWidth = $0 }

            levels
        }
        .foregroundStyle(Theme.meterText)
        .padding(.horizontal, size == .regular ? 30 : 18)
        .padding(.vertical, size == .regular ? 20 : 12)
        .frame(maxWidth: .infinity, maxHeight: isLarge ? .infinity : nil)
        .background(Theme.meterPanel, in: .rect(cornerRadius: 6))
    }

    private var badge: some View {
        let text = switch record.stage {
        case .setup: record.isListening ? "Listening" : "Not listening"
        case .checking: "Checking levels"
        case .recording: "Recording"
        case .finished: "Stopped"
        }
        return HStack(spacing: 7) {
            Circle()
                .fill(record.isRecording ? Theme.meterDot : Theme.dotIdle)
                .frame(width: isLarge ? 11 : 7, height: isLarge ? 11 : 7)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: isLarge ? 18 : 12))
        }
        .fixedSize()
    }

    /// The stage, and what a recording from this input is saved as: always 24-bit,
    /// at the rate the input is really running.
    private var top: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let rate = record.capture.snapshot.sampleRate
            HStack(spacing: 12) {
                badge
                Spacer(minLength: 0)
                Text(rate > 0 ? String(format: "24-bit / %g kHz", rate / 1000) : "24-bit")
                    .font(Theme.mono(isLarge ? 16 : 12))
                    .fixedSize()
            }
        }
        .frame(height: isLarge ? 26 : 16)
    }

    private var levels: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let snapshot = record.capture.snapshot
            HStack(spacing: 8) {
                Text("INPUT LEVEL")
                    .font(Theme.mono(isLarge ? 16 : 11))
                    .fixedSize()
                Spacer(minLength: 0)
                Circle()
                    .fill(snapshot.peakLit ? Color(red: 0.91, green: 0.27, blue: 0.165) : Theme.meterText.opacity(0.18))
                    .frame(width: isLarge ? 22 : 12, height: isLarge ? 22 : 12)
                    .shadow(color: snapshot.peakLit ? .red.opacity(0.8) : .clear, radius: 7)
                    .accessibilityLabel(snapshot.peakLit ? "Peak light on" : "Peak light off")
                Text(VUMeter.peakLabel(snapshot.recentPeak))
                    .font(Theme.mono(isLarge ? 16 : 12))
                    .fixedSize()
            }
        }
        .frame(height: isLarge ? 26 : 16)
    }
}

/// The needle and its scale, drawn on the meter panel.
private struct VUMeter: View {
    /// The space the scale is laid out in, which scales with the view.
    static let shape = CGSize(width: 560, height: 186)

    private static let scaleColor = Color(red: 0.843, green: 0.843, blue: 0.753)
    private static let overColor = Color(red: 0.725, green: 0.494, blue: 0.38)
    private static let needleColor = Color(red: 0.953, green: 0.835, blue: 0.639)

    let capture: AudioCapture

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let snapshot = capture.snapshot
            Canvas { context, size in
                draw(vu: snapshot.vu, in: size, context: context)
            }
            .accessibilityElement()
            .accessibilityLabel("Level meter")
            .accessibilityValue(Self.peakLabel(snapshot.recentPeak))
        }
    }

    static func peakLabel(_ peak: Double) -> String {
        peak <= -100 ? "Peak --" : String(format: "Peak %.1f dBFS", peak).replacingOccurrences(of: "-", with: "−")
    }

    private func draw(vu: Double, in size: CGSize, context: GraphicsContext) {
        let scale = min(size.width / Self.shape.width, size.height / Self.shape.height)
        let origin = CGPoint(
            x: (size.width - Self.shape.width * scale) / 2,
            y: (size.height - Self.shape.height * scale) / 2
        )
        func place(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        /// A point on the scale's arc, which curves around a centre far below it.
        func point(_ value: Double, radius: Double) -> CGPoint {
            let angle = (-35 + (value + 20) / 23 * 70) * .pi / 180
            return place(280 + sin(angle) * radius, 438 - cos(angle) * radius)
        }
        func arc(from: Double, to: Double) -> Path {
            var path = Path()
            let steps = 30
            for step in 0...steps {
                let value = from + (to - from) * Double(step) / Double(steps)
                let p = point(value, radius: 401)
                if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path
        }

        context.stroke(arc(from: -20, to: 0), with: .color(Self.scaleColor.opacity(0.5)), lineWidth: 1.5 * scale)
        context.stroke(arc(from: 0, to: 3), with: .color(Self.overColor), lineWidth: 6 * scale)

        let labelled = [-20.0, -10, -7, -5, -3, 0, 3]
        for mark in labelled + [-1, 1, 2] {
            var tick = Path()
            tick.move(to: point(mark, radius: 401))
            tick.addLine(to: point(mark, radius: labelled.contains(mark) ? 416 : 409))
            context.stroke(tick, with: .color(mark > 0 ? Self.overColor : Self.scaleColor), lineWidth: 2 * scale)
        }
        for mark in labelled {
            let text = Text(mark > 0 ? "+\(Int(mark))" : "\(Int(mark))")
                .font(.system(size: 16 * scale, design: .monospaced))
                .foregroundStyle(mark > 0 ? Self.overColor : Theme.meterText)
            context.draw(text, at: point(mark, radius: 380))
        }
        context.draw(
            Text("VU").font(Theme.serif(26 * scale)).foregroundStyle(Theme.meterText),
            at: place(244, 118)
        )

        let pivot = place(280, 178)
        var needle = Path()
        needle.move(to: pivot)
        needle.addLine(to: point(max(-22, min(4, vu)), radius: 408))
        context.stroke(needle, with: .color(Self.needleColor), style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round))
        context.fill(
            Path(ellipseIn: CGRect(x: pivot.x - 7 * scale, y: pivot.y - 7 * scale, width: 14 * scale, height: 14 * scale)),
            with: .color(Self.needleColor)
        )
    }
}

/// A picture of the last moments of input, to show that audio is arriving. The
/// newest is at the right.
private struct LiveStrip: View {
    /// Twelve seconds at ten readings a second.
    static let length = 120

    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(x: 0, y: size.height / 2, width: size.width, height: 1)), with: .color(Theme.scopeBorder))
            guard !levels.isEmpty else { return }
            let width = size.width / CGFloat(Self.length)
            for (index, level) in levels.enumerated() {
                let height = max(1, CGFloat(level) * (size.height - 6))
                let rect = CGRect(
                    x: size.width - CGFloat(levels.count - index) * width,
                    y: (size.height - height) / 2,
                    width: max(0.5, width - 1),
                    height: height
                )
                context.fill(Path(rect), with: .color(Theme.waveform))
            }
            context.fill(Path(CGRect(x: size.width - 1, y: 0, width: 1, height: size.height)), with: .color(Theme.needle))
        }
        .scopeBackground()
        .accessibilityHidden(true)
    }
}
