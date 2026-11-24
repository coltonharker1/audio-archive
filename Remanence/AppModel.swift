import AppKit
import Foundation
import Observation
import RemanenceCore
import ServiceManagement

enum ShelfFilter: String, CaseIterable, Identifiable {
    case all = "Shelf"
    case review = "Ready to Review"
    case progress = "In Progress"
    case site = "On the Site"

    var id: String { rawValue }

    func includes(_ tape: ShelfTape) -> Bool {
        switch self {
        case .all:
            return true
        case .review:
            return tape.tape.pushedAt == nil && tape.tape.approvedAt == nil && tape.status == .idle
        case .progress:
            if case .failed = tape.status { return true }
            return tape.status.isActive
        case .site:
            return tape.tape.pushedAt != nil
        }
    }
}

/// What the sidebar has chosen: one of the shelf's filters, or a collection.
enum SidebarItem: Hashable {
    case filter(ShelfFilter)
    case collection(Int64)
}

enum Route: Equatable {
    case shelf, search, readAlong, review, record, post, edit
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let paths = LibraryPaths.standard
    let requirements: [Requirement]
    let player = AudioPlayer()

    private(set) var states: [Requirement.ID: RequirementState] = [:]
    private(set) var downloads: [Requirement.ID: Double] = [:]
    private(set) var downloadErrors: [Requirement.ID: String] = [:]
    private(set) var hasChecked = false
    private(set) var database: AppDatabase?
    private(set) var databaseError: String?

    private(set) var shelf: [ShelfTape] = []
    private(set) var hasLoadedShelf = false
    private(set) var selectedTapeID: ShelfTape.ID?
    private(set) var selectedItemIndex = 0
    private(set) var importProgress: ImportProgress?
    private(set) var jobProgress: [Int64: Double] = [:]
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var route = Route.shelf
    private(set) var searchResults: [SearchTapeResult] = []
    private(set) var isSearching = false
    var searchRequested = false
    var editingLineID: Int64?
    var isComparingTranscripts = false
    var filter = ShelfFilter.all {
        didSet { if route != .shelf { leaveToShelf() } }
    }
    private(set) var collections: [ShelfCollection] = []
    /// Every RA number the site is using, so new tapes never take one of them.
    var siteNumbers: Set<String> = []
    /// The collection shown instead of a filter, if one is chosen in the sidebar.
    private(set) var selectedCollectionID: Int64?
    var message: String?
    var searchText = "" {
        didSet { if searchText != oldValue { runSearch() } }
    }

    @ObservationIgnored private var routeBeforeReadAlong = Route.shelf
    @ObservationIgnored private(set) lazy var reviewModel = ReviewModel(app: self)
    @ObservationIgnored private(set) lazy var recordModel = RecordModel(app: self)
    @ObservationIgnored private(set) lazy var pushModel = PushModel(app: self)
    @ObservationIgnored private(set) lazy var editModel = EditModel(app: self)
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var queue: JobQueue?
    @ObservationIgnored private var isObservingShelf = false

    private init() {
        requirements = SetupCatalog.requirements(paths: paths)
        do {
            try paths.createDirectories()
            database = try AppDatabase.open(at: paths.database)
        } catch {
            databaseError = error.localizedDescription
        }
        player.onFinished = { [weak self] in self?.playNextItem() }
    }

    var isReady: Bool {
        hasChecked && requirements.allSatisfy { $0.isOptional || states[$0.id] == .ready }
    }

    var library: Library? {
        database.map { Library(database: $0, paths: paths) }
    }

    var visibleTapes: [ShelfTape] {
        if let collection = selectedCollection {
            let byID = Dictionary(uniqueKeysWithValues: shelf.map { ($0.id, $0) })
            return collection.tapeIDs.compactMap { byID[$0] }
        }
        return shelf.filter(filter.includes)
    }

    var sidebarSelection: SidebarItem {
        get { selectedCollectionID.map(SidebarItem.collection) ?? .filter(filter) }
        set {
            switch newValue {
            case .filter(let chosen):
                selectedCollectionID = nil
                filter = chosen
            case .collection(let id):
                selectedCollectionID = id
                if route != .shelf { leaveToShelf() }
            }
        }
    }

    var selectedCollection: ShelfCollection? {
        collections.first { $0.id == selectedCollectionID }
    }

    /// The collection a tape is in, if any.
    func collection(of tape: ShelfTape) -> ShelfCollection? {
        tape.tape.collectionId.flatMap { id in collections.first { $0.id == id } }
    }

    var selectedTape: ShelfTape? {
        shelf.first { $0.id == selectedTapeID }
    }

    var selectedItem: ShelfTape.Item? {
        guard let items = selectedTape?.items, items.indices.contains(selectedItemIndex) else { return nil }
        return items[selectedItemIndex]
    }

    // MARK: Setup

    func refresh() async {
        for requirement in requirements where downloads[requirement.id] == nil {
            states[requirement.id] = await SetupCatalog.check(requirement)
        }
        hasChecked = true
        await startPipelineIfReady()
    }

    func download(_ requirement: Requirement) async {
        guard case .model(let source, let minimumBytes) = requirement.kind,
              downloads[requirement.id] == nil else { return }

        downloads[requirement.id] = 0
        downloadErrors[requirement.id] = nil
        do {
            try await ModelDownloader.download(
                from: source,
                to: requirement.path,
                minimumBytes: minimumBytes
            ) { [weak self] fraction in
                Task { @MainActor in
                    if self?.downloads[requirement.id] != nil {
                        self?.downloads[requirement.id] = fraction
                    }
                }
            }
        } catch {
            downloadErrors[requirement.id] = error.localizedDescription
        }
        downloads[requirement.id] = nil
        states[requirement.id] = await SetupCatalog.check(requirement)
        await startPipelineIfReady()
    }

    // MARK: Pipeline

    /// Starts background work once, as soon as every required tool is in place.
    private func startPipelineIfReady() async {
        guard isReady, queue == nil, let database else { return }

        let pipeline = Pipeline(database: database, paths: paths)
        let queue = JobQueue(
            database: database,
            tools: pipeline.tools,
            onProgress: { [weak self] id, fraction in
                Task { @MainActor in self?.jobProgress[id] = fraction }
            },
            handler: { job, context in try await pipeline.run(job, context: context) }
        )
        self.queue = queue
        observeSystemSleep(queue)

        do {
            // A recording cut off by a crash comes first, so it's on the shelf and
            // queued like any other before work starts.
            if let library {
                let recovered = try await library.recoverInterruptedCaptures()
                if !recovered.isEmpty {
                    message = "Recovered an interrupted recording: \(recovered.joined(separator: ", ")). Everything up to the interruption is saved."
                }
            }
            try await database.writer.write { db in
                try JobStore.enqueueMissingTranscripts(db) { pipeline.hasModel($0) }
                try JobStore.enqueueMissingPeaks(db)
            }
            try await queue.start()
        } catch {
            message = "Background processing couldn’t start. \(error.localizedDescription)"
        }
    }

    private func observeSystemSleep(_ queue: JobQueue) {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
            Task { await queue.systemWillSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            Task { await queue.systemDidWake() }
        }
    }

    /// Stops running tools and returns their jobs to the queue, ready for next launch.
    func shutDown() async {
        await queue?.stop()
    }

    func retry(_ tape: ShelfTape) async {
        guard let database else { return }
        let id = tape.id
        do {
            try await database.writer.write { db in try JobStore.retry(db, tapeID: id) }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Plain words for what's happening with a tape, or nil when it's settled.
    func activityText(for tape: ShelfTape) -> String? {
        if recordModel.isRecording, recordModel.recordingTapeID == tape.id { return "Recording…" }
        switch tape.status {
        case .idle:
            return nil
        case .waiting:
            return "Waiting to start"
        case .failed:
            return "Couldn’t finish"
        case .working(.prep, _):
            return "Getting ready…"
        case .working(.summarize, _):
            return "Writing a summary…"
        case .working(.peaks, _):
            return "Reading the waveform…"
        case .working(.transcribe, let jobID):
            if let fraction = jobProgress[jobID], fraction > 0 {
                return "Listening… \(Int(fraction * 100))%"
            }
            return "Listening…"
        }
    }

    /// A one-line summary for the menu bar.
    var pipelineSummary: String {
        let working = shelf.filter {
            if case .working = $0.status { return true }
            return false
        }
        let waiting = shelf.filter { $0.status == .waiting }.count
        let failed = shelf.filter {
            if case .failed = $0.status { return true }
            return false
        }.count

        var parts: [String] = []
        if !working.isEmpty {
            parts.append(working.count == 1 ? "1 tape in progress" : "\(working.count) tapes in progress")
        }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if failed > 0 { parts.append("\(failed) couldn’t finish") }
        return parts.isEmpty ? "All caught up" : parts.joined(separator: " · ")
    }

    var workingTapes: [ShelfTape] {
        shelf.filter {
            if case .working = $0.status { return true }
            return false
        }
    }

    // MARK: Recording

    func openRecording() {
        // Uploading and encoding could cause dropouts, and a pass of a tape can't be redone.
        guard !pushModel.isPushing else {
            message = "A push is running. Recording can start once it finishes."
            return
        }
        editModel.leave()
        // Recording from a collection records into it.
        if let selectedCollectionID, recordModel.recordingTapeID == nil {
            recordModel.collectionChoice = selectedCollectionID
        }
        route = .record
    }

    // MARK: Pushing

    func openPost(_ tape: ShelfTape) {
        routeBeforeReadAlong = route == .search ? .search : .shelf
        select(tape)
        route = .post
    }

    func leavePost() {
        leaveReadAlong()
    }

    func leaveRecording() {
        route = .shelf
    }

    func suspendPipelineForRecording() async {
        await queue?.suspendForRecording()
    }

    func resumePipeline() async {
        await queue?.setPaused(false)
    }

    func hasModel(_ name: String) -> Bool {
        guard let database else { return false }
        return Pipeline(database: database, paths: paths).hasModel(name)
    }

    // MARK: Read-along

    var backLabel: String {
        routeBeforeReadAlong == .search ? "Results" : "Shelf"
    }

    func openReadAlong(_ tape: ShelfTape) {
        routeBeforeReadAlong = route == .search ? .search : .shelf
        select(tape)
        route = .readAlong
    }

    func leaveReadAlong() {
        route = routeBeforeReadAlong == .search && !searchText.isEmpty ? .search : .shelf
    }

    func openReview(_ tape: ShelfTape) {
        routeBeforeReadAlong = route == .search ? .search : .shelf
        select(tape)
        route = .review
    }

    func leaveReview() {
        leaveReadAlong()
    }

    // MARK: Edit mode

    func openEdit(_ tape: ShelfTape) {
        routeBeforeReadAlong = route == .search ? .search : .shelf
        select(tape)
        player.pause()
        route = .edit
    }

    func leaveEdit() {
        editModel.leave()
        leaveReadAlong()
    }

    /// Keys for edit mode. Returns whether the key was used.
    func handleEditKey(code: UInt16, characters: String, shift: Bool) -> Bool {
        guard route == .edit else { return false }
        return editModel.handleKey(code: code, characters: characters, shift: shift)
    }

    /// Keys for the review screen. Returns whether the key was used.
    func handleReviewKey(code: UInt16, characters: String, shift: Bool) -> Bool {
        guard route == .review else { return false }
        return reviewModel.handleKey(code: code, characters: characters, shift: shift)
    }

    private func leaveToShelf() {
        route = .shelf
        searchText = ""
    }

    /// Changes track without starting playback.
    func choose(itemAt index: Int) {
        selectedItemIndex = index
        Task { await loadSelectedItem(thenPlay: false) }
    }

    func setApproved(_ tape: ShelfTape, _ approved: Bool) async {
        await perform { try await $0.setApproved(tapeID: tape.id, approved: approved) }
    }

    func setContext(_ tape: ShelfTape, _ context: String) async {
        await perform { try await $0.setContext(tapeID: tape.id, context: context) }
    }

    func requestSummary(_ tape: ShelfTape) async {
        await perform { try await $0.requestSummary(tapeID: tape.id) }
    }

    func updateLine(id: Int64, text: String) async {
        await perform { try await $0.updateSegment(id: id, text: text) }
    }

    func requestComparison(sourceID: Int64, model: String) async {
        await perform { try await $0.requestComparison(sourceID: sourceID, model: model) }
    }

    func keepCurrentTranscript(sourceID: Int64) async {
        await perform { try await $0.discardCandidate(sourceID: sourceID) }
    }

    func useCandidate(sourceID: Int64) async {
        await perform { try await $0.adoptCandidate(sourceID: sourceID) }
    }

    private func perform(_ action: (Library) async throws -> Void) async {
        guard let library else { return }
        do {
            try await action(library)
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Search

    func search(for text: String) {
        searchText = "\"\(text)\""
    }

    /// Waits for a short pause in typing, so results don't flicker on every key.
    private func runSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            if route == .search { route = .shelf }
            return
        }
        if route != .search { route = .search }
        isSearching = true

        guard let library else { return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            do {
                let results = try await library.search(query)
                guard !Task.isCancelled else { return }
                searchResults = results
            } catch is CancellationError {
                return
            } catch {
                message = "Search didn’t work. \(error.localizedDescription)"
            }
            isSearching = false
        }
    }

    /// Opens a search result, playing from the moment if one was chosen.
    func openResult(_ result: SearchTapeResult, moment: SearchMoment?) {
        guard let tape = shelf.first(where: { $0.id == result.tapeID }) else { return }
        routeBeforeReadAlong = .search

        let index = moment.flatMap { moment in
            tape.items.firstIndex { $0.source.id == moment.sourceID }
        } ?? 0
        let needsLoad = selectedTapeID != tape.id || selectedItemIndex != index
        selectedTapeID = tape.id
        selectedItemIndex = index
        route = .readAlong

        Task {
            if needsLoad || player.currentURL == nil {
                await loadSelectedItem(thenPlay: false)
            }
            if let moment {
                await player.seek(to: moment.time)
                player.play()
            }
        }
    }

    // MARK: Open at login

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "This couldn’t be changed. \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Shelf

    /// Keeps the shelf matching the database for as long as the app runs.
    func observeShelf() async {
        guard let library, !isObservingShelf else { return }
        isObservingShelf = true
        do {
            for try await tapes in library.shelfUpdates() {
                shelf = tapes
                hasLoadedShelf = true
                if let selectedTapeID, !tapes.contains(where: { $0.id == selectedTapeID }) {
                    self.selectedTapeID = nil
                    player.stop()
                    if route == .readAlong || route == .review || route == .post || route == .edit { route = .shelf }
                }
            }
        } catch {
            message = "Your shelf couldn’t be loaded. \(error.localizedDescription)"
        }
        isObservingShelf = false
    }

    // MARK: Collections

    /// Keeps the collections matching the database for as long as the app runs.
    func observeCollections() async {
        guard let library else { return }
        do {
            for try await update in library.collectionUpdates() {
                collections = update
                if let selectedCollectionID, !update.contains(where: { $0.id == selectedCollectionID }) {
                    self.selectedCollectionID = nil
                }
            }
        } catch {
            message = "Your collections couldn’t be loaded. \(error.localizedDescription)"
        }
    }

    /// Makes a collection, optionally with tapes in it, and opens it.
    func createCollection(named name: String, with tapes: [ShelfTape] = []) async {
        guard let library else { return }
        do {
            let id = try await Task.detached { try await library.createCollection(name: name) }.value
            for tape in tapes {
                let tapeID = tape.id
                try await Task.detached { try await library.setCollection(tapeID: tapeID, collectionID: id) }.value
            }
            sidebarSelection = .collection(id)
        } catch {
            message = error.localizedDescription
        }
    }

    func setCollection(_ tape: ShelfTape, to collectionID: Int64?) async {
        let tapeID = tape.id
        await performDetached { try await $0.setCollection(tapeID: tapeID, collectionID: collectionID) }
    }

    func moveInCollection(_ tapeID: Int64, to place: Int) async {
        await performDetached { try await $0.moveInCollection(tapeID: tapeID, to: place) }
    }

    func saveCollection(_ id: Int64, fields: CollectionFields) async {
        await performDetached { try await $0.saveCollection(id: id, fields: fields) }
    }

    func deleteCollection(_ id: Int64) async {
        await performDetached { try await $0.deleteCollection(id: id) }
    }

    /// Runs a change away from the calling task, so it's saved even if the view
    /// that asked for it goes away.
    func performDetached(_ action: @escaping @Sendable (Library) async throws -> Void) async {
        guard let library else { return }
        do {
            try await Task.detached { try await action(library) }.value
        } catch {
            message = error.localizedDescription
        }
    }

    func select(_ tape: ShelfTape) {
        guard selectedTapeID != tape.id else { return }
        selectedTapeID = tape.id
        selectedItemIndex = 0
        Task { await loadSelectedItem(thenPlay: false) }
    }

    func togglePlayback() {
        player.togglePlayback()
    }

    func play(itemAt index: Int) {
        selectedItemIndex = index
        Task { await loadSelectedItem(thenPlay: true) }
    }

    private func playNextItem() {
        guard let items = selectedTape?.items, selectedItemIndex + 1 < items.count else { return }
        play(itemAt: selectedItemIndex + 1)
    }

    private func loadSelectedItem(thenPlay: Bool) async {
        guard let item = selectedItem, let library else { return }
        do {
            let url = try library.url(forLibraryPath: item.source.masterPath)
            let loaded = await player.load(url, duration: item.source.duration)
            if loaded && thenPlay { player.play() }
        } catch {
            message = error.localizedDescription
        }
    }

    func delete(_ tape: ShelfTape) async {
        guard pushModel.pushingTapeID != tape.id else {
            message = "This tape is being pushed. Stop the push before deleting it."
            return
        }
        guard let library else { return }
        if recordModel.isRecording, recordModel.recordingTapeID == tape.id {
            message = "This tape is still recording."
            return
        }
        if selectedTapeID == tape.id {
            player.stop()
            selectedTapeID = nil
        }
        do {
            try await library.delete(tapeID: tape.id)
        } catch {
            message = "“\(tape.tape.title)” couldn’t be moved to the Trash. \(error.localizedDescription)"
        }
    }

    /// Removes one recording from a tape, moving its audio to the Trash.
    func removeSide(_ item: ShelfTape.Item, of tape: ShelfTape) async {
        guard let library else { return }
        if recordModel.isRecording, recordModel.recordingTapeID == tape.id {
            message = "This tape is still recording."
            return
        }
        if selectedTapeID == tape.id {
            player.stop()
            selectedItemIndex = 0
        }
        let sourceID = item.id
        do {
            try await Task.detached {
                try await library.removeSide(sourceID: sourceID)
            }.value
        } catch {
            message = "\(item.name) couldn’t be deleted. \(error.localizedDescription)"
        }
    }

    func renameSide(_ item: ShelfTape.Item, to name: String) async {
        guard let library else { return }
        let sourceID = item.id
        do {
            try await Task.detached {
                try await library.renameSide(sourceID: sourceID, to: name)
            }.value
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Adding audio

    /// Adds dropped files and folders, reporting only what needs attention.
    func add(_ urls: [URL]) async {
        guard let database else { return }
        let pipeline = Pipeline(database: database, paths: paths)
        var importer = DropImporter(database: database, paths: paths) { pipeline.hasModel($0) }
        importer.reservedNumbers = siteNumbers

        let task = Task.detached(priority: .userInitiated) { await importer.add(urls) }
        let summary = await task.value

        var notes: [String] = []
        if !summary.alreadyInLibrary.isEmpty {
            notes.append("Already on your shelf: \(summary.alreadyInLibrary.joined(separator: ", ")).")
        }
        if !summary.notAudio.isEmpty {
            notes.append("Not audio Remanence can read: \(summary.notAudio.joined(separator: ", ")).")
        }
        notes += summary.failed
        if !notes.isEmpty { message = notes.joined(separator: "\n\n") }
    }

    func chooseBackupToImport() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Remanence backup folder"
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Music")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await importBackup(from: folder) }
    }

    /// Queues transcripts and waveforms for audio that arrived without them.
    func queueNewAudio() async {
        guard let database else { return }
        let pipeline = Pipeline(database: database, paths: paths)
        try? await database.writer.write { db in
            try JobStore.enqueueMissingTranscripts(db) { pipeline.hasModel($0) }
            try JobStore.enqueueMissingPeaks(db)
        }
    }

    func importBackup(from folder: URL) async {
        guard let database, importProgress == nil else { return }
        importProgress = ImportProgress(tape: "", completedFiles: 0, totalFiles: 0)

        let importer = BackupImporter(database: database, paths: paths)
        let task = Task.detached(priority: .userInitiated) {
            try await importer.run(from: folder) { update in
                Task { @MainActor [weak self] in
                    if self?.importProgress != nil { self?.importProgress = update }
                }
            }
        }

        do {
            let summary = try await task.value
            if summary.imported.isEmpty {
                message = "Everything in this backup is already on your shelf."
            } else {
                let pipeline = Pipeline(database: database, paths: paths)
                try await database.writer.write { db in
                    try JobStore.enqueueMissingTranscripts(db) { pipeline.hasModel($0) }
                    try JobStore.enqueueMissingPeaks(db)
                }
            }
        } catch {
            message = "The import stopped. \(error.localizedDescription) Nothing was changed in your backup."
        }
        importProgress = nil
    }
}
