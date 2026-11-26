import AppKit
import AVFoundation
import Observation
import RemanenceCore
import UserNotifications

/// Runs a recording session: setup, the level check, capture and side flips.
@MainActor
@Observable
final class RecordModel {
    enum Stage: Equatable {
        case setup
        case checking(secondsLeft: Int)
        case recording
        case finished
    }

    private(set) var stage = Stage.setup
    private(set) var machines: [Machine] = []
    private(set) var devices: [InputDevice] = []
    private(set) var checkResult: String?
    private(set) var advice = LevelAdvice.noSignal
    private(set) var clock: Double = 0
    private(set) var dropouts = 0
    private(set) var askingIfFinished = false
    private(set) var markerTimes: [Double] = []
    private(set) var diskWarning: String?
    private(set) var permissionDenied = false
    private(set) var recordingTapeID: Int64?
    private(set) var currentSide = "A"
    /// The tape's RA number: the one it will get, before Record, and the one it has after.
    private(set) var catalogNumber: String?
    /// What the next side will be called, from the tape's sides as they are now.
    private(set) var nextSide = "B"
    /// The side just recorded, which can be recorded again.
    private(set) var lastRecordedSourceID: Int64?
    /// True from Stop until the side is saved. Until then the side and next-side
    /// values still describe the previous side, so nothing should act on them.
    private(set) var isFinishing = false
    private(set) var isLarge = false
    private(set) var isListening = false
    private(set) var audioStalled = false
    /// Why the input isn't listening. Stays on screen, unlike the app's passing messages.
    private(set) var inputProblem: String?

    var selectedMachineID: Int64?
    var selectedSpeed: String?
    var tapeName = ""
    /// The collection the tape goes in, `newCollection` for one made from
    /// `newCollectionName`, or nil. It stays chosen for the next tape from the same box.
    var collectionChoice: Int64?
    var newCollectionName = ""
    static let newCollection: Int64 = -1
    var knobNote = ""
    var selectedDeviceUID: String?
    var channelMode = ChannelMode.first

    @ObservationIgnored let capture = AudioCapture()
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var target: CaptureTarget?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var lastAlert = Date.distantPast
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var listeningTo: (uid: String, mode: ChannelMode)?
    @ObservationIgnored private var restarts: [Date] = []
    @ObservationIgnored private var lastBufferCount = 0
    @ObservationIgnored private var lastBufferDate = Date()
    /// Set when the screen is left while a side is still saving, so it closes after.
    @ObservationIgnored private var closeWhenFinished = false

    init(app: AppModel) {
        self.app = app
        capture.onInterrupted = { [weak self] reason in
            Task { @MainActor in await self?.handleInterruption(reason) }
        }
        capture.onInputChanged = { [weak self] in
            Task { @MainActor in self?.restartAfterInputChange() }
        }
    }

    var isRecording: Bool { stage == .recording }
    var selectedMachine: Machine? { machines.first { $0.id == selectedMachineID } }
    var selectedDevice: InputDevice? {
        devices.first { $0.uid == selectedDeviceUID } ?? devices.first
    }

    // MARK: Opening and closing

    func open() async {
        // Coming back before a side finished saving keeps the screen as it was.
        closeWhenFinished = false
        guard !isListening else { return }
        guard await requestMicrophone() else {
            permissionDenied = true
            return
        }
        permissionDenied = false
        if let library = app.library {
            machines = (try? await library.machines()) ?? []
        }
        devices = AudioCapture.inputDevices()
        if selectedMachineID == nil { selectMachine(machines.first) }
        stage = .setup
        startListening()
        startMonitor()
        await refreshCatalogNumber()
        // The site may have numbers this library doesn't, so check, then look again.
        await app.pushModel.refreshSiteNumbers()
        await refreshCatalogNumber()
    }

    /// Works out the number the next tape will get. A tape being recorded keeps its own.
    func refreshCatalogNumber() async {
        guard recordingTapeID == nil, let library = app.library else { return }
        catalogNumber = try? await library.nextCatalogNumber(excluding: app.siteNumbers)
    }

    /// Stops the meter when leaving the screen. Refuses while recording, so a stray
    /// click can never end a pass of a tape.
    func close() {
        guard !isRecording else { return }
        // Resetting now would drop the side being saved and let a new take start
        // under it, so closing waits until the save is done.
        guard !isFinishing else {
            closeWhenFinished = true
            return
        }
        monitor?.cancel()
        monitor = nil
        checkTask?.cancel()
        capture.stop()
        isListening = false
        listeningTo = nil
        isLarge = false
        stage = .setup
        target = nil
        recordingTapeID = nil
        lastRecordedSourceID = nil
        checkResult = nil
        saveMachineSettings()
    }

    private func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func toggleLarge() { isLarge.toggle() }

    // MARK: Setup

    func selectMachine(_ machine: Machine?) {
        saveMachineSettings()
        selectedMachineID = machine?.id
        selectedSpeed = machine?.speedOptions.first
        knobNote = machine?.knobNote ?? ""
        // A remembered input is only reused if it's real hardware, or the only choice.
        if let uid = machine?.deviceUid,
           let saved = devices.first(where: { $0.uid == uid }),
           saved.kind != .virtual || devices.first?.uid == uid {
            selectedDeviceUID = uid
        } else {
            selectedDeviceUID = devices.first?.uid
        }
        channelMode = machine?.channelMode.flatMap(ChannelMode.init) ?? .first
        if isListening { startListening() }
    }

    func saveMachineSettings() {
        guard let id = selectedMachineID, let library = app.library else { return }
        let note = knobNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let uid = selectedDeviceUID
        let mode = channelMode.rawValue
        Task { try? await library.updateMachine(id: id, knobNote: note.isEmpty ? nil : note, deviceUID: uid, channelMode: mode) }
    }

    func inputChanged() {
        checkResult = nil
        if isListening { startListening() }
    }

    private func startListening() {
        guard let device = selectedDevice else {
            app.message = "No audio input was found. Connect your interface and try again."
            return
        }
        // Switching machines often keeps the same input, so nothing needs to restart.
        if isListening, let current = listeningTo, current.uid == device.uid, current.mode == channelMode { return }
        do {
            try capture.start(device: device, mode: channelMode)
            listeningTo = (device.uid, channelMode)
            isListening = true
            inputProblem = nil
        } catch {
            isListening = false
            listeningTo = nil
            inputProblem = error.localizedDescription
        }
    }

    /// Restarts listening once things settle. It's limited so a device that keeps
    /// changing can't make this restart endlessly.
    private func restartAfterInputChange() {
        guard isListening, !isRecording else { return }
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 30 } + [now]
        guard restarts.count <= 5 else {
            isListening = false
            listeningTo = nil
            audioStalled = false
            capture.stop()
            inputProblem = "This input keeps changing, so it was stopped. Check your interface and reopen this screen."
            return
        }
        listeningTo = nil
        startListening()
    }

    // MARK: Level check

    /// Listens to the loudest part of a tape, without saving anything.
    func startLevelCheck(seconds: Int = 20) {
        checkResult = nil
        capture.resetChannelCheck()
        checkTask?.cancel()
        checkTask = Task {
            for left in stride(from: seconds, to: 0, by: -1) {
                stage = .checking(secondsLeft: left)
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            finishLevelCheck()
        }
    }

    func cancelLevelCheck() {
        checkTask?.cancel()
        stage = .setup
    }

    private func finishLevelCheck() {
        let snapshot = capture.snapshot
        stage = .setup

        var result: String
        switch snapshot.advice {
        case .noSignal: result = "No sound came through. Check the cable and that the tape is playing."
        case .tooQuiet: result = "Too quiet. Turn the machine’s output up and check again."
        case .fine: result = "A little low, but usable. Turning it up a touch would be better."
        case .good: result = "Levels look good. Leave everything as it is."
        case .hot: result = "A little hot. Turn the machine’s output down slightly."
        case .clipping: result = "Clipping. Turn the machine’s output down and check again."
        }

        switch snapshot.channelFinding {
        case .identical where channelMode == .stereo:
            channelMode = .first
            inputChanged()
            result += " Both inputs carry the same audio, so this tape will record as mono."
        case .onlyFirst where channelMode != .first:
            channelMode = .first
            inputChanged()
            result += " Only Input 1 has sound, so it’s switched to that."
        case .onlySecond where channelMode != .second:
            channelMode = .second
            inputChanged()
            result += " Only Input 2 has sound, so it’s switched to that."
        default:
            break
        }
        checkResult = result
    }

    // MARK: Recording

    func startRecording() async {
        guard let library = app.library, isListening, !isFinishing else { return }
        do {
            let target: CaptureTarget
            if let tapeID = recordingTapeID {
                target = try await library.beginNextSide(tapeID: tapeID)
            } else {
                target = try await library.beginCapture(
                    machine: selectedMachine,
                    title: tapeName,
                    speed: selectedSpeed,
                    collectionID: await chosenCollection(library),
                    excludingNumbers: app.siteNumbers
                )
                let tapeID = target.tapeID
                catalogNumber = try? await library.database.writer.read { db in
                    try String.fetchOne(db, sql: "SELECT catalog_number FROM tape WHERE id = ?", arguments: [tapeID])
                }
            }
            await app.suspendPipelineForRecording()
            try capture.startRecording(to: target.url)
            self.target = target
            recordingTapeID = target.tapeID
            currentSide = target.side
            markerTimes = []
            lastBufferDate = Date()
            askingIfFinished = false
            diskWarning = nil
            checkResult = nil
            stage = .recording
            saveMachineSettings()
            requestNotificationPermission()
        } catch {
            await app.resumePipeline()
            app.message = "The recording couldn’t start. \(error.localizedDescription)"
        }
    }

    func addMarker() {
        guard isRecording else { return }
        markerTimes.append(capture.snapshot.seconds)
    }

    func stopRecording() async {
        guard isRecording else { return }
        capture.stopRecording()
        await finish()
    }

    private func finish() async {
        askingIfFinished = false
        isFinishing = true
        lastRecordedSourceID = nil
        stage = .finished
        if capture.snapshot.seconds == 0 {
            app.message = "No audio arrived, so nothing was saved. Check your interface and cable, then try again."
        }
        if let target, let library = app.library {
            do {
                try await library.finishCapture(sourceID: target.sourceID, markers: markerTimes)
            } catch {
                app.message = "The recording is safe, but it couldn’t be finished yet. It’ll be recovered next time Remanence opens. \(error.localizedDescription)"
            }
            // An empty recording is cleared away, so there's nothing to record again.
            let kept = try? await library.database.writer.read { db in try Source.fetchOne(db, key: target.sourceID) }
            lastRecordedSourceID = kept == nil ? nil : target.sourceID
            nextSide = (try? await library.nextSide(tapeID: target.tapeID)) ?? nextSide
        }
        isFinishing = false
        target = nil
        if closeWhenFinished {
            closeWhenFinished = false
            close()
        }
        await app.resumePipeline()
    }

    private func handleInterruption(_ reason: String) async {
        guard isRecording else { return }
        await finish()
        isListening = false
        listeningTo = nil
        alert(sound: "Basso", title: "Recording stopped", body: reason)
        app.message = "Recording stopped. \(reason) Everything up to that point is saved."
    }

    /// For quitting mid-recording: closes the file properly first.
    func stopForQuit() async {
        await stopRecording()
        close()
    }

    func tapeFinishedConfirmed() async {
        await stopRecording()
    }

    func keepRecording() {
        askingIfFinished = false
        capture.dismissTapeEnd()
    }

    func recordNextSide() async {
        guard !isFinishing else { return }
        await startRecording()
    }

    /// Records the side just finished again from the start. The take being replaced
    /// goes to the Trash first, so it can still be got back from Finder.
    func reRecordLastSide() async {
        guard stage == .finished, !isFinishing, isListening, let sourceID = lastRecordedSourceID, let library = app.library else { return }
        // Processing starts as soon as a side finishes. Pausing puts it back in the
        // queue, so nothing is working on the take while it's removed.
        await app.suspendPipelineForRecording()
        do {
            try await Task.detached {
                try await library.removeSide(sourceID: sourceID, allowingLast: true)
            }.value
        } catch {
            await app.resumePipeline()
            app.message = "Side \(currentSide) couldn’t be moved to the Trash, so it’s still here. \(error.localizedDescription)"
            return
        }
        lastRecordedSourceID = nil
        await startRecording()
    }

    func reviewRecording() {
        guard !isFinishing, let tapeID = recordingTapeID,
              let tape = app.shelf.first(where: { $0.id == tapeID }) else { return }
        close()
        app.openReview(tape)
    }

    /// The collection to record into, making it first if it's new. A collection that
    /// can't be made never stops the recording; it's just recorded outside one.
    private func chosenCollection(_ library: Library) async -> Int64? {
        guard let choice = collectionChoice else { return nil }
        guard choice == Self.newCollection else { return choice }
        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        do {
            let id = try await Task.detached { try await library.createCollection(name: name) }.value
            collectionChoice = id
            newCollectionName = ""
            return id
        } catch {
            app.message = "The collection couldn’t be made, so this tape isn’t in one. \(error.localizedDescription)"
            return nil
        }
    }

    /// Starts over with a new tape after finishing one.
    func startAnotherTape() {
        recordingTapeID = nil
        target = nil
        tapeName = ""
        currentSide = "A"
        nextSide = "B"
        lastRecordedSourceID = nil
        stage = .setup
        catalogNumber = nil
        Task { await refreshCatalogNumber() }
    }

    // MARK: Watching the signal

    private func startMonitor() {
        monitor?.cancel()
        monitor = Task {
            var tick = 0
            while !Task.isCancelled {
                updateFromSnapshot(tick: tick)
                tick += 1
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func updateFromSnapshot(tick: Int) {
        let snapshot = capture.snapshot
        advice = snapshot.advice
        clock = snapshot.seconds
        dropouts = snapshot.dropouts

        // No blocks arriving looks just like silence on the meter, so it's checked
        // directly. Otherwise a stalled input could waste a whole pass of a tape.
        if snapshot.buffersReceived != lastBufferCount {
            lastBufferCount = snapshot.buffersReceived
            lastBufferDate = Date()
            audioStalled = false
        } else if isListening, Date().timeIntervalSince(lastBufferDate) > 3 {
            if !audioStalled, isRecording {
                alert(sound: "Basso", title: "No audio is arriving", body: "The input has stopped sending audio. Check your interface.")
            }
            audioStalled = true
        }

        guard isRecording else { return }

        // Asked when the machine stops, not when the tape goes quiet: reels often have
        // long gaps between recordings. The question goes away if the tape runs again.
        if snapshot.machineStopped, !askingIfFinished {
            askingIfFinished = true
            alert(sound: "Glass", title: "Has the tape finished?", body: "The machine seems to have stopped. Remanence is still recording.",
                  identifier: "tape-finished")
        } else if askingIfFinished, !snapshot.machineStopped {
            askingIfFinished = false
        }

        // Clipping is told straight away. Being too quiet waits, so a pause near the
        // start of a tape doesn't set it off.
        if snapshot.advice == .clipping {
            throttledAlert(sound: "Basso", title: "Clipping", body: "Turn the machine’s output down and start again.")
        } else if snapshot.advice == .tooQuiet, snapshot.seconds > 30 {
            throttledAlert(sound: "Funk", title: "Too quiet", body: "Turn the machine’s output up and start again.")
        }

        if tick % 150 == 0, let device = selectedDevice, let url = target?.url {
            checkDisk(url: url, rate: snapshot.sampleRate, channels: channelMode.indicesCount(for: device))
        }
    }

    private func checkDisk(url: URL, rate: Double, channels: Int) {
        guard let hours = AudioCapture.hoursAvailable(on: url, sampleRate: rate, channels: channels) else { return }
        if hours < 0.02 {
            Task { await stopRecording() }
            alert(sound: "Basso", title: "Disk full", body: "Recording stopped because the disk is nearly full. What was recorded is safe.")
            app.message = "Recording stopped because the disk is nearly full. What was recorded is safe."
        } else if hours < 0.5 {
            diskWarning = "Only about \(Int(hours * 60)) minutes of disk space left."
        }
    }

    private func throttledAlert(sound: String, title: String, body: String) {
        guard Date().timeIntervalSince(lastAlert) > 30 else { return }
        lastAlert = Date()
        alert(sound: sound, title: title, body: body)
    }

    /// A sound carries across the room to the tape machine. A notification stays
    /// visible if you're away from the screen.
    private func alert(sound: String, title: String, body: String, identifier: String? = nil) {
        NSSound(named: sound)?.play()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier ?? UUID().uuidString, content: content, trigger: nil)
        )
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
}

extension ChannelMode {
    func indicesCount(for device: InputDevice) -> Int {
        self == .stereo && device.channels > 1 ? 2 : 1
    }
}
