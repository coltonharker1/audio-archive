import RemanenceCore
import SwiftUI

/// Where a tape gets recorded. The meter is the centerpiece, and can fill the window
/// so it reads from across the room at the tape machine.
struct RecordView: View {
    @Environment(AppModel.self) private var model

    private var record: RecordModel { model.recordModel }

    var body: some View {
        Group {
            if record.permissionDenied {
                permissionNeeded
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button {
                            record.close()
                            model.leaveRecording()
                        } label: {
                            Label("Shelf", systemImage: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .tint(Theme.accent)
                        .disabled(record.isRecording)
                        .help(record.isRecording ? "Stop recording first" : "Back to the shelf")

                        Spacer()

                        Button(record.isLarge ? "Show Setup" : "Large Meter", systemImage: record.isLarge ? "sidebar.left" : "arrow.up.left.and.arrow.down.right") {
                            record.toggleLarge()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                    HStack(spacing: 0) {
                        if !record.isLarge && !record.isRecording {
                            RecordSetup()
                                .frame(width: 250)
                            Rectangle().fill(Theme.board.opacity(0.6)).frame(width: 1)
                        }
                        RecordStage()
                    }
                }
            }
        }
        .background(Theme.paper)
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
                .padding(.top, 6)
            Button("Check Again") { Task { await record.open() } }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Choosing the machine, speed and input.
private struct RecordSetup: View {
    @Environment(AppModel.self) private var model

    private var record: RecordModel { model.recordModel }

    var body: some View {
        @Bindable var record = record

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Machine") {
                    VStack(spacing: 4) {
                        ForEach(record.machines) { machine in
                            let isSelected = machine.id == record.selectedMachineID
                            Button {
                                record.selectMachine(machine)
                            } label: {
                                Text(machine.name)
                                    .font(.system(size: 13))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 32)
                                    .foregroundStyle(isSelected ? Theme.paper : Theme.ink)
                                    .background(isSelected ? Theme.ink : Theme.card, in: .rect(cornerRadius: 7))
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                }

                section("Speed") {
                    Picker("Speed", selection: $record.selectedSpeed) {
                        ForEach(record.selectedMachine?.speedOptions ?? [], id: \.self) { speed in
                            Text(speed).tag(String?.some(speed))
                        }
                        Text("Unknown").tag(String?.none)
                    }
                    .labelsHidden()
                }

                section("Name (optional)") {
                    TextField("What’s written on the box?", text: $record.tapeName)
                        .textFieldStyle(.roundedBorder)
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

                    if (record.selectedDevice?.channels ?? 1) > 1 {
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

                section("Notes for this machine") {
                    TextField("Output knob at about 6", text: $record.knobNote)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { record.saveMachineSettings() }
                    Text("This appears next time you choose this machine.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .padding(16)
        }
        .background(Theme.paper.opacity(0.6))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
            content()
        }
    }
}

/// The meter, what it means, and what to do next.
private struct RecordStage: View {
    @Environment(AppModel.self) private var model

    private var record: RecordModel { model.recordModel }

    var body: some View {
        VStack(spacing: 16) {
            VUMeter(capture: record.capture)
                .frame(maxWidth: record.isLarge ? .infinity : 520)
                .frame(maxHeight: record.isLarge ? .infinity : 360)

            status

            if record.isRecording, !record.askingIfFinished {
                LiveStrip(capture: record.capture)
                    .frame(maxWidth: 620)
                    .frame(height: 40)
            }

            if record.askingIfFinished {
                tapeEndQuestion
            }

            buttons
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var status: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(Theme.display(record.isLarge ? 54 : 32))
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: record.isLarge ? 18 : 14))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
            if record.dropouts > 0 {
                Text(record.dropouts == 1 ? "1 dropout detected. Listen to this recording afterward." : "\(record.dropouts) dropouts detected. Listen to this recording afterward.")
                    .font(.callout)
                    .foregroundStyle(Theme.attention)
            }
            if record.audioStalled {
                Text("No audio is arriving from this input. Check your interface and cable.")
                    .font(.callout)
                    .foregroundStyle(Theme.attention)
            }
            if let warning = record.diskWarning {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(Theme.attention)
            }
        }
        .frame(maxWidth: 620)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch record.stage {
        case .checking: return "Play the loudest part of the tape"
        case .finished: return "Recording saved"
        case .setup:
            return record.checkResult == nil ? adviceTitle : "Level check finished"
        case .recording:
            return "\(TimeLabel.clock(record.clock)) · \(adviceTitle)"
        }
    }

    private var adviceTitle: String {
        switch record.advice {
        case .noSignal: "No signal"
        case .tooQuiet: "Too quiet"
        case .fine: "A little low"
        case .good: "Levels look good"
        case .hot: "A little hot"
        case .clipping: "Clipping"
        }
    }

    private var detail: String {
        switch record.stage {
        case .checking(let left):
            return "Listening for \(left) more seconds. Nothing is being saved."
        case .finished:
            return "Side \(record.currentSide), \(TimeLabel.clock(record.clock)). Transcribing in the background."
        case .setup:
            if let problem = record.inputProblem { return problem }
            if let result = record.checkResult { return result }
            if !record.knobNote.isEmpty { return "Last time: \(record.knobNote)" }
            return record.isListening ? "Check your levels, or press Record and then play the tape." : "Getting the input ready…"
        case .recording:
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

    private var titleColor: Color {
        if case .finished = record.stage { return Theme.good }
        switch record.advice {
        case .good: return Theme.good
        case .clipping, .tooQuiet: return Theme.attention
        case .hot: return Theme.accent
        case .noSignal, .fine: return Theme.ink
        }
    }

    private var tapeEndQuestion: some View {
        HStack(spacing: 12) {
            Text("Tape finished?")
                .font(Theme.display(24))
                .foregroundStyle(Theme.ink)
            Button("Yes, Stop Recording") { Task { await record.tapeFinishedConfirmed() } }
                .buttonStyle(.borderedProminent)
            Button("Keep Recording") { record.keepRecording() }
        }
        .padding(14)
        .background(Theme.card, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            switch record.stage {
            case .setup:
                Button("Check Levels") { record.startLevelCheck() }
                    .controlSize(.large)
                    .disabled(!record.isListening)
                recordButton
            case .checking:
                Button("Cancel") { record.cancelLevelCheck() }
                    .controlSize(.large)
            case .recording:
                Button(record.markerTimes.isEmpty ? "Add Marker" : "Add Marker (\(record.markerTimes.count))", systemImage: "flag.fill") {
                    record.addMarker()
                }
                .controlSize(.large)
                Button {
                    Task { await record.stopRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ink)
                .controlSize(.large)
            case .finished:
                Button("Record Side \(nextSide)") { Task { await record.recordNextSide() } }
                    .controlSize(.large)
                    .disabled(!record.isListening)
                Button("New Tape") { record.startAnotherTape() }
                    .controlSize(.large)
                Button("Review and Add Markers") { record.reviewRecording() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    private var recordButton: some View {
        Button {
            Task { await record.startRecording() }
        } label: {
            Label("Record", systemImage: "record.circle")
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.attention)
        .controlSize(.large)
        .disabled(!record.isListening)
    }

    private var nextSide: String {
        String(UnicodeScalar(UInt8(min(90, (record.currentSide.utf8.first ?? 65) + 1))))
    }
}

/// An analog-style needle with a peak light that stays lit long enough to notice.
struct VUMeter: View {
    let capture: AudioCapture

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let snapshot = capture.snapshot
            VStack(spacing: 10) {
                Canvas { context, size in
                    draw(vu: snapshot.vu, in: size, context: context)
                }
                .aspectRatio(400.0 / 228.0, contentMode: .fit)
                .background(Color(red: 0.965, green: 0.937, blue: 0.851), in: .rect(cornerRadius: 6))
                .clipShape(.rect(cornerRadius: 6))

                HStack(spacing: 8) {
                    Circle()
                        .fill(snapshot.peakLit ? Color(red: 0.91, green: 0.27, blue: 0.165) : Color(red: 0.357, green: 0.318, blue: 0.27))
                        .frame(width: 16, height: 16)
                        .shadow(color: snapshot.peakLit ? .red.opacity(0.8) : .clear, radius: 7)
                    Text(peakLabel(snapshot.recentPeak))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(red: 0.941, green: 0.922, blue: 0.871))
                    Spacer()
                    if snapshot.isRecording {
                        HStack(spacing: 5) {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Text("RECORDING")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.941, green: 0.922, blue: 0.871))
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .padding(14)
            .background(Color(red: 0.165, green: 0.145, blue: 0.118), in: .rect(cornerRadius: 14))
            .accessibilityElement()
            .accessibilityLabel("Level meter")
            .accessibilityValue(peakLabel(snapshot.recentPeak))
        }
    }

    private func peakLabel(_ peak: Double) -> String {
        peak <= -100 ? "PEAK --" : String(format: "PEAK %.0f DB", peak)
    }

    /// Lays out the scale in a 400 by 228 space, which scales with the view.
    private func draw(vu: Double, in size: CGSize, context: GraphicsContext) {
        let scale = size.width / 400
        let pivot = CGPoint(x: 200 * scale, y: 222 * scale)
        let ink = Color(red: 0.106, green: 0.094, blue: 0.078)
        let red = Color(red: 0.659, green: 0.196, blue: 0.102)

        func angle(_ value: Double) -> Double { (-48 + (value + 20) / 23 * 96) * .pi / 180 }
        func point(_ value: Double, radius: Double) -> CGPoint {
            let a = angle(value)
            return CGPoint(
                x: pivot.x + CGFloat(sin(a) * radius) * scale,
                y: pivot.y - CGFloat(cos(a) * radius) * scale
            )
        }
        func arc(from: Double, to: Double) -> Path {
            var path = Path()
            let steps = 30
            for step in 0...steps {
                let value = from + (to - from) * Double(step) / Double(steps)
                let p = point(value, radius: 165)
                if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path
        }

        context.stroke(arc(from: -20, to: 0), with: .color(ink), lineWidth: 2 * scale)
        context.stroke(arc(from: 0, to: 3), with: .color(red), lineWidth: 8 * scale)

        for mark in [-20.0, -10, -7, -5, -3, -1, 0, 1, 2, 3] {
            var tick = Path()
            tick.move(to: point(mark, radius: 150))
            tick.addLine(to: point(mark, radius: 165))
            context.stroke(tick, with: .color(mark > 0 ? red : ink), lineWidth: 2 * scale)
        }
        for mark in [-20.0, -10, -7, -5, -3, 0, 3] {
            let text = Text(mark > 0 ? "+\(Int(mark))" : "\(Int(mark))")
                .font(.system(size: 12 * scale, design: .monospaced))
                .foregroundStyle(mark > 0 ? red : ink)
            context.draw(text, at: point(mark, radius: 180))
        }
        context.draw(
            Text("VU").font(.system(size: 30 * scale, design: .serif)).foregroundStyle(ink),
            at: CGPoint(x: pivot.x, y: 160 * scale)
        )

        let clamped = max(-22, min(4, vu))
        var needle = Path()
        needle.move(to: pivot)
        needle.addLine(to: point(clamped, radius: 174))
        context.stroke(needle, with: .color(ink), style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round))
        context.fill(
            Path(ellipseIn: CGRect(x: pivot.x - 12 * scale, y: pivot.y - 12 * scale, width: 24 * scale, height: 24 * scale)),
            with: .color(Color(red: 0.165, green: 0.145, blue: 0.118))
        )
    }
}

/// A scrolling picture of the last moments, to show that audio is arriving.
private struct LiveStrip: View {
    let capture: AudioCapture
    @State private var levels: [Float] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10)) { timeline in
            Canvas { context, size in
                guard !levels.isEmpty else { return }
                let width = size.width / 120
                for (index, level) in levels.enumerated() {
                    let height = max(1, CGFloat(level) * size.height)
                    let rect = CGRect(
                        x: size.width - CGFloat(levels.count - index) * width,
                        y: (size.height - height) / 2,
                        width: max(0.5, width - 1),
                        height: height
                    )
                    context.fill(Path(rect), with: .color(Theme.accent))
                }
            }
            .onChange(of: timeline.date) { _, _ in
                // -70 dB to 0 dB, the same scale as the review waveform.
                let level = Float(max(0, min(1, (capture.snapshot.peak + 70) / 70)))
                levels.append(level)
                if levels.count > 120 { levels.removeFirst() }
            }
        }
        .accessibilityHidden(true)
    }
}
