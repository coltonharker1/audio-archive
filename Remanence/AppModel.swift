import AppKit
import Foundation
import Observation
import RemanenceCore
import ServiceManagement

/// What the sidebar offers, and so what it can highlight.
enum SidebarItem: Hashable {
    case recording, shelf, catalog, sitePosts
    case collection(Int64)
    case setup
}

enum Route: Equatable {
    case shelf, search, readAlong, review, record, post, edit, catalog, sitePosts, setup

    /// The screens of one tape, in the order their tabs show.
    static let tapeTabs: [Route] = [.review, .edit, .readAlong, .post]

    /// What this screen's tab says, or nil when it isn't one of a tape's.
    var tabTitle: String? {
        switch self {
        case .review: "Review"
        case .edit: "Edit"
        case .readAlong: "Read Along"
        case .post: "Site Post"
        case .shelf, .search, .record, .catalog, .sitePosts, .setup: nil
        }
    }

    var isTapeTab: Bool { tabTitle != nil }

    /// This screen as a saved position names it, or nil when it isn't one of a tape's.
    var workTab: WorkPosition.Tab? {
        switch self {
        case .review: .review
        case .edit: .edit
        case .readAlong: .readAlong
        case .post: .post
        case .shelf, .search, .record, .catalog, .sitePosts, .setup: nil
        }
    }

    init(_ tab: WorkPosition.Tab) {
        switch tab {
        case .review: self = .review
        case .edit: self = .edit
        case .readAlong: self = .readAlong
        case .post: self = .post
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let paths: LibraryPaths
    /// Whether `-libraryPath` pointed this launch away from the real library.
    let usesScratchLibrary: Bool
    let requirements: [Requirement]
    let player = AudioPlayer()

    private(set) var states: [Requirement.ID: RequirementState] = [:]
    private(set) var downloads: [Requirement.ID: Double] = [:]
    private(set) var downloadErrors: [Requirement.ID: String] = [:]
    private(set) var hasChecked = false
    private(set) var database: AppDatabase?
    private(set) var databaseError: String?

    private(set) var shelf: [ShelfTape] = []
    /// Worked out once for each shelf update, since reading a tape's site snapshot
    /// is too slow to do for every row on every redraw.
    private var shelfStatuses: [ShelfTape.ID: ShelfStatus] = [:]
    private(set) var hasLoadedShelf = false
    private(set) var selectedTapeID: ShelfTape.ID?
    private(set) var selectedItemIndex = 0
    private(set) var importProgress: ImportProgress?
    private(set) var jobProgress: [Int64: Double] = [:]
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var route = Route.shelf {
        didSet {
            if route != oldValue { footerNote = nil }
            // What was waiting to be restored belongs to the visit just ended.
            if oldValue.isTapeTab && !route.isTapeTab {
                restoringPlayhead = nil
                reviewModel.discardPendingZoom()
                editModel.discardPendingPlace()
            }
        }
    }
    /// Where work last stopped, kept between launches.
    private var savedPosition: WorkPosition?
    /// The zoom Review had on each recording when it was last left.
    @ObservationIgnored private var leftReviewZooms: [Int64: (start: Double, span: Double)] = [:]
    /// A playhead being put back while its recording is still loading.
    @ObservationIgnored private var restoringPlayhead: (sourceID: Int64, time: Double)?
    @ObservationIgnored private let positionKey: String
    /// What the screen showing wants said in the footer. Nil leaves the summary of
    /// background work there. It's cleared on the way to another screen.
    var footerNote: String?
    /// The footer's note, longest wording first. The footer shows the first that fits.
    var footerWordings: [String] {
        // Review's note is its keys, which are the same for every tape.
        if route == .review {
            return [
                "Space Play / pause · J K L Shuttle · M Add marker",
                "Space Play / pause · M Add marker",
                "M Add marker",
            ]
        }
        if route == .edit {
            return ["Edits apply to playback and site copies · Master preserved"]
        }
        if route == .catalog, let note = catalogStaging.pending(in: shelf).footerNote {
            return [note]
        }
        return [footerNote ?? pipelineSummary]
    }
    /// More than the footer has room for, shown when the pointer rests on its note.
    var footerHelp: String? {
        if route == .edit {
            return "Space Play / pause · ← → Skip 5 s · M Split at playhead · ⌥ Split exactly · - = Zoom"
                + " · Esc Close the close-up · Drag a waveform’s edges to trim"
        }
        guard route == .review else { return nil }
        return "Space Play / pause · M Add marker · H Hear the join · ← → Nudge · , . Previous or next marker"
            + " · J K L Shuttle · - = Zoom · I O Trim the side · ⌘Z Undo"
    }
    private(set) var searchResults: [SearchTapeResult] = []
    private(set) var isSearching = false
    var searchRequested = false
    var editingLineID: Int64?
    var isComparingTranscripts = false
    /// The shelf's chosen tab.
    var filter = ShelfFilter.all {
        didSet { if route != .shelf { leaveToShelf() } }
    }
    private(set) var collections: [ShelfCollection] = []
    /// Every RA number the site is using, so new tapes never take one of them.
    var siteNumbers: Set<String> = []
    /// New RA numbers lined up in the Catalog. Kept while other screens are used, and
    /// never saved, so they're gone at Apply, Revert or quit.
    private(set) var catalogStaging = CatalogStaging()
    private(set) var isApplyingCatalog = false
    /// Why a typed number or the last Apply was refused.
    private(set) var catalogFailure: String?
    /// The collection shown instead of the shelf, if one is chosen in the sidebar.
    private(set) var selectedCollectionID: Int64? {
        didSet { if selectedCollectionID != oldValue { footerNote = nil } }
    }
    var message: String?
    var searchText = "" {
        didSet { if searchText != oldValue { runSearch() } }
    }

    /// Where the tape on screen was opened from.
    private(set) var tapeOrigin = TapeOrigin.shelf
    @ObservationIgnored private var routeBeforeSearch = Route.shelf
    @ObservationIgnored private(set) lazy var reviewModel = ReviewModel(app: self)
    @ObservationIgnored private(set) lazy var recordModel = RecordModel(app: self)
    @ObservationIgnored private(set) lazy var pushModel = PushModel(app: self)
    @ObservationIgnored private(set) lazy var editModel = EditModel(app: self)
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var queue: JobQueue?
    @ObservationIgnored private var isObservingShelf = false

    private init() {
        let choice = Self.libraryChoice()
        var paths = LibraryPaths.standard
        if case .scratch(let folder) = choice {
            paths = LibraryPaths(library: folder, support: paths.support)
        }
        self.paths = paths
        if case .scratch = choice { usesScratchLibrary = true } else { usesScratchLibrary = false }
        // A scratch library keeps its own place, leaving the real library's alone.
        if case .scratch(let folder) = choice {
            positionKey = "workPosition:\(folder.path)"
        } else {
            positionKey = "workPosition"
        }
        savedPosition = UserDefaults.standard.data(forKey: positionKey)
            .flatMap { try? JSONDecoder().decode(WorkPosition.self, from: $0) }
        requirements = SetupCatalog.requirements(paths: paths)
        if case .unusable = choice {
            // Asking for a scratch library must never open the real one instead.
            databaseError = "-libraryPath needs the full path of a folder."
        } else {
            do {
                try paths.createDirectories()
                database = try AppDatabase.open(at: paths.database)
            } catch {
                databaseError = error.localizedDescription
            }
        }
        player.onFinished = { [weak self] in self?.playNextItem() }
    }

    private enum LibraryChoice {
        case standard
        case scratch(URL)
        case unusable
    }

    /// `-libraryPath <folder>` at launch opens a scratch library, for trying things
    /// without touching the real one. Only the launch arguments are read, so a saved
    /// default can never move a normal launch elsewhere. Models stay where they are.
    private static func libraryChoice() -> LibraryChoice {
        guard CommandLine.arguments.contains("-libraryPath") else { return .standard }
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let path = arguments["libraryPath"] as? String, path.hasPrefix("/") else { return .unusable }
        return .scratch(URL(filePath: path, directoryHint: .isDirectory))
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
        get {
            // Search shows where clearing it will go back to.
            switch route == .search ? routeAfterSearch : route {
            case .record: .recording
            case .catalog: .catalog
            case .sitePosts: .sitePosts
            case .setup: .setup
            // A tape's screens belong to the shelf or the collection.
            case .shelf, .search, .readAlong, .review, .post, .edit:
                selectedCollectionID.map(SidebarItem.collection) ?? .shelf
            }
        }
        set {
            switch newValue {
            case .recording:
                // Choosing it again mustn't undo the collection picked on that screen.
                guard route != .record else { return }
                openRecording()
                if route == .record { searchText = "" }
            case .shelf:
                selectedCollectionID = nil
                leaveToShelf()
            case .collection(let id):
                selectedCollectionID = id
                leaveToShelf()
            case .catalog:
                leave(to: .catalog)
            case .sitePosts:
                leave(to: .sitePosts)
            case .setup:
                leave(to: .setup)
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

    /// Where a tape stands, for its badge. Words for anything still happening come
    /// from `activityText`.
    func status(of tape: ShelfTape) -> ShelfStatus {
        if recordModel.isRecording, recordModel.recordingTapeID == tape.id { return .recording }
        return shelfStatuses[tape.id] ?? ShelfStatus(tape)
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
        rememberPosition()
        editModel.leave()
        // Recording from a collection records into it.
        if let selectedCollectionID, recordModel.recordingTapeID == nil {
            recordModel.collectionChoice = selectedCollectionID
        }
        route = .record
    }

    // MARK: Pushing

    func openPost(_ tape: ShelfTape) {
        select(tape)
        show(tab: .post)
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

    // MARK: A tape's screens

    func openReadAlong(_ tape: ShelfTape) {
        select(tape)
        show(tab: .readAlong)
    }

    func openReview(_ tape: ShelfTape) {
        select(tape)
        show(tab: .review)
    }

    func openEdit(_ tape: ShelfTape) {
        select(tape)
        show(tab: .edit)
    }

    /// Moves between the tabs of the tape on screen. Back still leads where it did.
    func switchTab(_ tab: Route) {
        guard route.isTapeTab, tab.isTapeTab, tab != route else { return }
        rememberPosition()
        show(tab: tab)
    }

    private func show(tab: Route) {
        noteOrigin()
        // Edit plays through its own player.
        if tab == .edit { player.pause() }
        route = tab
    }

    /// Call before the route changes to one of a tape's screens.
    private func noteOrigin() {
        tapeOrigin = tapeOrigin.entering(
            fromTapeScreen: route.isTapeTab,
            fromSearch: route == .search,
            collectionID: selectedCollectionID
        )
    }

    /// Where Back goes from the tape on screen.
    var backDestination: TapeOrigin {
        tapeOrigin.back(searchText: searchText, collections: Set(collections.map(\.id)))
    }

    func goBack() {
        rememberPosition()
        if route == .edit { editModel.leave() }
        switch backDestination {
        case .results:
            route = .search
        case .collection(let id):
            selectedCollectionID = id
            route = .shelf
        case .shelf:
            selectedCollectionID = nil
            route = .shelf
        }
    }

    // MARK: Resuming

    /// The place Resume leads to, while its tape is still on the shelf.
    var resumable: WorkPosition.Resolved? {
        savedPosition?.resolved(in: shelf)
    }

    /// Saves where work is on the tape on screen, and does nothing anywhere else.
    /// Call it before the route changes, since a screen that goes away lets go of
    /// what it had selected.
    func rememberPosition() {
        guard let tab = route.workTab, let tape = selectedTape, let item = selectedItem,
              let selectedSourceID = item.source.id else { return }
        let earlier = savedPosition.flatMap { $0.tapeUUID == tape.tape.uuid ? $0 : nil }
        // Edit that hasn't shown its tracks yet, or has already let go of them,
        // has nothing newer to say.
        if tab == .edit, !editModel.isShowingTracks(of: tape.id), earlier?.tab == .edit { return }

        var position = WorkPosition(tapeUUID: tape.tape.uuid, tab: tab, sourceID: selectedSourceID, playhead: 0)
        if let restoring = restoringPlayhead, restoring.sourceID == selectedSourceID {
            position.playhead = restoring.time
        } else if player.failure == nil, let url = player.currentURL,
                  url == (try? library?.url(forLibraryPath: item.source.masterPath)) {
            position.playhead = player.preciseTime
        } else if let earlier, earlier.sourceID == selectedSourceID {
            position.playhead = earlier.playhead
        }

        // Edit has a player of its own, which may be on another recording.
        if tab == .edit, editModel.isShowingTracks(of: tape.id) {
            if let loaded = editModel.loadedPosition {
                position.sourceID = loaded.sourceID
                position.playhead = loaded.time
            }
            position.editTrackID = editModel.expandedLaneID
        }

        if tab == .review, let zoom = reviewModel.zoom(of: position.sourceID) {
            leftReviewZooms[position.sourceID] = zoom
            position.zoomStart = zoom.start
            position.zoomSpan = zoom.span
        } else if let earlier, earlier.sourceID == position.sourceID {
            position.zoomStart = earlier.zoomStart
            position.zoomSpan = earlier.zoomSpan
        }

        savedPosition = position
        if let data = try? JSONEncoder().encode(position) {
            UserDefaults.standard.set(data, forKey: positionKey)
        }
    }

    /// Opens the last tape worked on where it was left, without starting playback.
    func resume() {
        guard let resumable else { return }
        let position = resumable.position
        let item = resumable.item
        selectedTapeID = resumable.tape.id
        selectedItemIndex = resumable.itemIndex
        player.pause()
        if let start = position.zoomStart, let span = position.zoomSpan {
            reviewModel.restoreZoom(sourceID: position.sourceID, start: start, span: span)
        }
        if position.tab == .edit {
            editModel.restore(
                tapeID: resumable.tape.id,
                trackID: position.editTrackID,
                sourceID: position.sourceID,
                time: position.playhead
            )
        }
        show(tab: Route(position.tab))
        restorePlayhead(to: position.playhead, in: item, reloading: true)
    }

    /// Puts the playhead on a moment of the chosen recording, without playing,
    /// loading the recording first when it's asked for.
    private func restorePlayhead(to time: Double, in item: ShelfTape.Item, reloading: Bool) {
        guard let sourceID = item.source.id else { return }
        restoringPlayhead = (sourceID, time)
        Task {
            if reloading { await load(item, thenPlay: false) }
            // Leaving the tape, or choosing another recording, calls this off.
            guard let restoring = restoringPlayhead, restoring.sourceID == sourceID,
                  selectedItem?.source.id == restoring.sourceID else { return }
            if player.failure == nil { await player.seek(to: restoring.time) }
            restoringPlayhead = nil
        }
    }

    // MARK: Between Review and Edit

    /// Opens Edit on the track under Review's playhead, at the same moment.
    func editSelectedTrack() {
        guard route == .review, let tape = selectedTape, let sourceID = selectedItem?.source.id else { return }
        reviewModel.pause()
        let restoring = restoringPlayhead.flatMap { $0.sourceID == sourceID ? $0.time : nil }
        // Opens the track the screen names, which follows the coarser currentTime.
        let starts = reviewModel.review.flatMap { $0.source.id == sourceID ? $0.tracks.map(\.start) : nil } ?? []
        let precise = TrackHandoff.time(player.preciseTime, onTrackAt: player.currentTime, starts: starts)
        let place = TrackHandoff.Place(sourceID: sourceID, time: restoring ?? precise)
        rememberPosition()
        editModel.arrive(tapeID: tape.id, at: place)
        show(tab: .edit)
    }

    /// Goes back to Review on the recording and moment Edit is at, zoomed as
    /// Review was.
    func returnToSide() {
        guard route == .edit, let tape = selectedTape else { return }
        // Read first: leaving Edit clears its selection and stops its player.
        guard let departure = editModel.departure,
              let index = tape.items.firstIndex(where: { $0.source.id == departure.sourceID }) else {
            switchTab(.review)
            return
        }
        rememberPosition()

        let item = tape.items[index]
        let duration = item.source.duration
        let zoom = leftReviewZooms[departure.sourceID] ?? reviewModel.zoom(of: departure.sourceID)
        // With no zoom to go back to, Review's usual one goes around the moment.
        let span = zoom?.span ?? min(90, max(ReviewModel.minimumSpan, duration))
        let start = zoom?.start ?? departure.time - span / 2
        reviewModel.restoreZoom(
            sourceID: departure.sourceID,
            start: TrackHandoff.zoomStart(start, span: span, showing: departure.time, duration: duration),
            span: span
        )

        let url = try? library?.url(forLibraryPath: item.source.masterPath)
        let isLoaded = player.failure == nil && player.currentURL != nil && player.currentURL == url
        selectedItemIndex = index
        player.pause()
        show(tab: .review)
        restorePlayhead(to: departure.time, in: item, reloading: !isLoaded)
    }

    // MARK: Keys

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

    /// Return opens the tape picked on the shelf or in a collection. Returns whether
    /// the key was used.
    func handleShelfKey(code: UInt16) -> Bool {
        // Return, or Enter on a number pad.
        guard route == .shelf, code == 36 || code == 76, let tape = selectedTape,
              visibleTapes.contains(where: { $0.id == tape.id }) else { return false }
        openReview(tape)
        return true
    }

    private func leaveToShelf() {
        rememberPosition()
        route = .shelf
        searchText = ""
    }

    /// Goes to a library-wide screen, which no collection is part of.
    private func leave(to destination: Route) {
        rememberPosition()
        selectedCollectionID = nil
        route = destination
        searchText = ""
    }

    /// Changes track without starting playback.
    func choose(itemAt index: Int) {
        restoringPlayhead = nil
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
            if route == .search { route = routeAfterSearch }
            return
        }
        if route != .search {
            rememberPosition()
            routeBeforeSearch = route
            route = .search
        }
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

    /// Where clearing the search goes. The recorder and a tape's screens aren't
    /// reopened, so those lead to the shelf or the collection.
    private var routeAfterSearch: Route {
        switch routeBeforeSearch {
        case .catalog, .sitePosts, .setup: routeBeforeSearch
        case .shelf, .search, .readAlong, .review, .record, .post, .edit: .shelf
        }
    }

    /// Opens a search result, playing from the moment if one was chosen.
    func openResult(_ result: SearchTapeResult, moment: SearchMoment?) {
        guard let tape = shelf.first(where: { $0.id == result.tapeID }) else { return }
        let index = moment.flatMap { moment in
            tape.items.firstIndex { $0.source.id == moment.sourceID }
        } ?? 0
        let needsLoad = selectedTapeID != tape.id || selectedItemIndex != index
        selectedTapeID = tape.id
        selectedItemIndex = index
        noteOrigin()
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
                shelfStatuses = Dictionary(uniqueKeysWithValues: tapes.map { ($0.id, ShelfStatus($0)) })
                shelf = tapes
                hasLoadedShelf = true
                followCatalog()
                if let selectedTapeID, !tapes.contains(where: { $0.id == selectedTapeID }) {
                    self.selectedTapeID = nil
                    player.stop()
                    if route.isTapeTab { route = .shelf }
                }
            }
        } catch {
            message = "Your shelf couldn’t be loaded. \(error.localizedDescription)"
        }
        isObservingShelf = false
    }

    // MARK: Catalog

    /// Brings the Catalog's list up to date with the shelf.
    func followCatalog() {
        var staging = catalogStaging
        staging.follow(shelf)
        guard staging != catalogStaging else { return }
        // A refusal may have been about a change that's now gone.
        if staging.staged != catalogStaging.staged { catalogFailure = nil }
        catalogStaging = staging
    }

    /// Opening the Catalog with nothing staged starts it fresh.
    func openCatalogList() {
        followCatalog()
        if catalogStaging.staged.isEmpty && !isApplyingCatalog { catalogFailure = nil }
    }

    func moveInCatalog(_ tapeIDs: [Int64], before: Int64?) {
        guard !isApplyingCatalog else { return }
        catalogStaging.move(tapeIDs, before: before, in: shelf)
        catalogFailure = nil
    }

    func typeCatalogNumber(_ text: String, for tapeID: Int64) {
        guard !isApplyingCatalog else { return }
        switch catalogStaging.commitTyping(text, for: tapeID, in: shelf) {
        case .restored: break
        case .staged: catalogFailure = nil
        case .refused(let reason): catalogFailure = reason
        }
    }

    func revertCatalog() {
        catalogStaging.reset(shelf)
        catalogFailure = nil
    }

    /// Renumbers on the site first, then here. A refusal keeps what's staged.
    func applyCatalog() {
        let changes = catalogStaging.changes(in: shelf)
        guard !changes.isEmpty, !isApplyingCatalog else { return }
        isApplyingCatalog = true
        catalogFailure = nil
        Task {
            do {
                try await pushModel.renumber(changes)
                revertCatalog()
                message = changes.count == 1 ? "Renumbered 1 reel. Relabel its box." : "Renumbered \(changes.count) reels. Relabel their boxes."
            } catch {
                catalogFailure = error.localizedDescription
                // Gone to another screen meanwhile, so it's said where it'll be seen.
                if route != .catalog { message = error.localizedDescription }
            }
            isApplyingCatalog = false
        }
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
        guard let item = selectedItem else { return }
        await load(item, thenPlay: thenPlay)
    }

    private func load(_ item: ShelfTape.Item, thenPlay: Bool) async {
        guard let library else { return }
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
        var removed = false
        do {
            try await Task.detached {
                try await library.removeSide(sourceID: sourceID)
            }.value
            removed = true
        } catch {
            message = "\(item.name) couldn’t be deleted. \(error.localizedDescription)"
        }
        // The tape's screens stay open, so the first recording left is made ready to
        // play. It's picked from `tape`, since the shelf may not have caught up.
        if selectedTapeID == tape.id, let first = tape.items.first(where: { !removed || $0.id != sourceID }) {
            await load(first, thenPlay: false)
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

    func chooseAudioToImport() {
        let panel = NSOpenPanel()
        panel.message = "Choose recordings. A folder becomes one tape, with a track for each file."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await add(urls) }
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
