import AppKit
import Foundation
import Observation
import RemanenceCore

enum ShelfFilter: String, CaseIterable, Identifiable {
    case all = "Shelf"
    case review = "Ready to Review"
    case site = "On the Site"

    var id: String { rawValue }

    func includes(_ tape: ShelfTape) -> Bool {
        switch self {
        case .all: true
        case .review: tape.tape.pushedAt == nil && tape.tape.approvedAt == nil
        case .site: tape.tape.pushedAt != nil
        }
    }
}

@MainActor
@Observable
final class AppModel {
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
    var filter = ShelfFilter.all
    var message: String?

    init() {
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

    var visibleTapes: [ShelfTape] { shelf.filter(filter.includes) }

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
    }

    // MARK: Shelf

    /// Keeps the shelf matching the database for as long as the app runs.
    func observeShelf() async {
        guard let library else { return }
        do {
            for try await tapes in library.shelfUpdates() {
                shelf = tapes
                hasLoadedShelf = true
                if let selectedTapeID, !tapes.contains(where: { $0.id == selectedTapeID }) {
                    self.selectedTapeID = nil
                    player.stop()
                }
            }
        } catch {
            message = "Your shelf couldn’t be loaded. \(error.localizedDescription)"
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
        guard let library else { return }
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

    // MARK: Import

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
            }
        } catch {
            message = "The import stopped. \(error.localizedDescription) Nothing was changed in your backup."
        }
        importProgress = nil
    }
}
