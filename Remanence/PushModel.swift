import Foundation
import Observation
import RemanenceCore

/// Runs a push and keeps its progress, so it carries on when the window closes or the
/// screen changes.
@MainActor
@Observable
final class PushModel {
    private(set) var plan: PushPlan?
    private(set) var planProblem: String?
    private(set) var hasKey = SiteCredentials.load() != nil
    private(set) var pushingTapeID: Int64?
    private(set) var progress: PushProgress?
    private(set) var failure: String?
    private(set) var finished: (tapeID: Int64, result: PushResult)?
    /// A refresh or update of a post already on the site.
    private(set) var syncingTapeID: Int64?
    private(set) var syncFailure: String?
    private(set) var syncNote: String?
    /// Which tape the note or failure is about.
    private(set) var lastSyncedTapeID: Int64?
    /// Goes up after each refresh, so the screen reloads what it's showing.
    private(set) var refreshes = 0
    /// Every post on the site, matched to tapes here.
    private(set) var siteListing: [SiteListing]?
    private(set) var listingFailure: String?
    private(set) var isListing = false
    /// The post being brought in, and how many of its tracks have arrived.
    private(set) var importingNumber: String?
    private(set) var importProgress: (done: Int, total: Int)?
    private(set) var importFailure: String?
    /// A collection being sent to the site or removed from it, and how that went.
    private(set) var syncingCollectionID: Int64?
    private(set) var collectionNote: (id: Int64, text: String)?
    private(set) var collectionFailure: (id: Int64, text: String)?

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var task: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
    }

    var isPushing: Bool {
        pushingTapeID != nil || syncingTapeID != nil || importingNumber != nil || syncingCollectionID != nil
    }

    /// Lets a test point the app somewhere other than the real site.
    var siteURL: URL {
        UserDefaults.standard.string(forKey: "siteURL").flatMap(URL.init(string:)) ?? SiteClient.defaultURL
    }

    func load(_ tape: ShelfTape) async {
        guard let library = app.library else { return }
        if pushingTapeID != tape.id { failure = nil }
        do {
            plan = try await library.pushPlan(tapeID: tape.id)
            planProblem = nil
        } catch {
            plan = nil
            planProblem = error.localizedDescription
        }
    }

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if SiteCredentials.save(trimmed) {
            hasKey = true
        } else {
            failure = "The key couldn’t be saved to the Keychain."
        }
    }

    func start(_ tape: ShelfTape) {
        guard !isPushing, let library = app.library, let key = SiteCredentials.load() else { return }
        guard !app.recordModel.isRecording else {
            failure = "Finish recording before pushing."
            return
        }
        let tapeID = tape.id
        let pusher = Pusher(library: library, site: SiteClient(baseURL: siteURL, apiKey: key))
        pushingTapeID = tapeID
        failure = nil
        finished = nil
        progress = nil

        task = Task { [self] in
            // Long uploads shouldn't stop because the Mac went idle.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Pushing a tape to the site"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                let result = try await pusher.push(tapeID: tapeID) { update in
                    Task { @MainActor [self] in
                        // A late update must not overwrite the finished state.
                        guard pushingTapeID == tapeID else { return }
                        progress = update
                    }
                }
                finish(tapeID: tapeID, result: result)
            } catch is CancellationError {
                finish(failure: nil)
            } catch let error as URLError where error.code == .cancelled {
                finish(failure: nil)
            } catch {
                finish(failure: error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Posts already on the site

    func refresh(_ tape: ShelfTape) {
        sync(tape) { pusher in
            let result = try await pusher.refresh(tapeID: tape.id)
            var notes = ["Loaded what the site has now."]
            if result.unmatchedTracks > 0 {
                notes.append("\(result.unmatchedTracks) \(result.unmatchedTracks == 1 ? "track" : "tracks") couldn’t be matched to the site’s.")
            }
            if !result.photosSkipped.isEmpty {
                notes.append("\(result.photosSkipped.count) \(result.photosSkipped.count == 1 ? "photo" : "photos") couldn’t be downloaded.")
            }
            return notes.joined(separator: " ")
        }
    }

    func update(_ tape: ShelfTape) {
        sync(tape) { [self] pusher in
            let changes = try await pusher.update(tapeID: tape.id) { update in
                Task { @MainActor [self] in
                    guard syncingTapeID == tape.id else { return }
                    progress = update
                }
            }
            return changes.isEmpty ? "Nothing to send." : "Updated on the site: \(changes.summary.joined(separator: ", "))."
        }
    }

    func setPublished(_ tape: ShelfTape, _ published: Bool) {
        sync(tape) { pusher in
            try await pusher.setPublished(tapeID: tape.id, published)
            return published ? "Published. It’s visible on the site now." : "Unpublished. It’s hidden from the site now."
        }
    }

    func deleteFromSite(_ tape: ShelfTape) {
        sync(tape) { pusher in
            let number = tape.tape.catalogNumber ?? "The post"
            try await pusher.deleteFromSite(tapeID: tape.id)
            return "\(number) was deleted from the site. The tape is still here, ready to push again."
        }
    }

    // MARK: Catalog numbers

    /// Learns which numbers the site is using. Quietly does nothing without a key or a
    /// connection; the site refuses a taken number at push time anyway.
    func refreshSiteNumbers() async {
        guard let site = client(), let entries = try? await site.listEntries() else { return }
        app.siteNumbers = Set(entries.map(\.catalogNumber))
    }

    /// Gives tapes new numbers, on the site first for tapes that are there.
    func renumber(_ changes: [Renumbering]) async throws {
        guard let library = app.library else { return }
        guard !isPushing else { throw RenumberBusy() }
        let site: any SiteAPI = client() ?? SiteClient(baseURL: siteURL, apiKey: "")
        try await Pusher(library: library, site: site).renumber(changes)
        await refreshSiteNumbers()
    }

    struct RenumberBusy: LocalizedError {
        var errorDescription: String? { "Something is being sent to the site. Try again when it finishes." }
    }

    // MARK: Collections

    /// Sends a collection to the site. `publish` changes whether it's public.
    func pushCollection(_ id: Int64, publish: Bool? = nil) {
        collectionWork(id) { pusher in
            let state = try await pusher.pushCollection(id: id, publish: publish) { update in
                Task { @MainActor [self] in
                    guard syncingCollectionID == id else { return }
                    progress = update
                }
            }
            var note: String
            switch publish {
            case true?: note = "Published at remanencearchive.com/collections/\(state.slug)."
            case false?: note = "Unpublished. It’s hidden from the site now."
            case nil: note = state.published ? "The site has the latest." : "On the site as a draft. Publish it when it’s ready."
            }
            if !state.missingReels.isEmpty {
                let count = state.missingReels.count
                note += " \(count) \(count == 1 ? "reel isn’t" : "reels aren’t") on the site yet, so \(count == 1 ? "it joins" : "they join") when pushed."
            }
            return note
        }
    }

    /// Removes a collection from the site, and from the library too if `andHere`.
    func removeCollectionFromSite(_ id: Int64, andHere: Bool = false) {
        collectionWork(id) { [self] pusher in
            try await pusher.deleteCollectionFromSite(id: id)
            if andHere {
                await app.deleteCollection(id)
                return "Deleted here and from the site."
            }
            return "Removed from the site. Its reels are still there, outside any collection."
        }
    }

    private func collectionWork(_ id: Int64, _ work: @escaping @Sendable (Pusher) async throws -> String) {
        guard !isPushing else {
            collectionFailure = (id, "Something else is being sent to the site. Try again when it finishes.")
            return
        }
        guard let library = app.library, let site = client() else {
            collectionFailure = (id, "Enter the site’s sync API key first, on any tape’s Site Post.")
            return
        }
        let pusher = Pusher(library: library, site: site)
        syncingCollectionID = id
        collectionNote = nil
        collectionFailure = nil
        progress = nil
        task = Task { [self] in
            do {
                collectionNote = (id, try await work(pusher))
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                collectionFailure = (id, error.localizedDescription)
            }
            syncingCollectionID = nil
            progress = nil
        }
    }

    /// After a reel is pushed, its collection on the site is sent again so the reel
    /// joins it there.
    private func joinCollectionOnSite(tapeID: Int64) {
        guard let library = app.library else { return }
        Task { [self] in
            guard let id = try? await library.collectionOnSite(tapeID: tapeID) else { return }
            pushCollection(id)
        }
    }

    // MARK: Every post on the site

    private func client() -> SiteClient? {
        SiteCredentials.load().map { SiteClient(baseURL: siteURL, apiKey: $0) }
    }

    func loadListing() async {
        guard let library = app.library, let site = client() else {
            listingFailure = "Enter the site’s sync API key first, on any tape’s Site Post."
            return
        }
        isListing = true
        defer { isListing = false }
        do {
            let entries = try await site.listEntries()
            siteListing = try await library.siteListing(entries)
            listingFailure = nil
        } catch {
            listingFailure = error.localizedDescription
        }
    }

    func importEntry(_ listing: SiteListing) {
        guard !isPushing, !app.recordModel.isRecording, let library = app.library, let site = client() else { return }
        let pusher = Pusher(library: library, site: site)
        let number = listing.entry.catalogNumber
        let owner = listing.entry.tapeUuid
        importingNumber = number
        importProgress = nil
        importFailure = nil
        task = Task { [self] in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Bringing in a post from the site"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                _ = try await pusher.importEntry(catalogNumber: number, tapeUUID: owner, progress: { done, total in
                    Task { @MainActor [self] in
                        if importingNumber == number { importProgress = (done, total) }
                    }
                })
                await app.queueNewAudio()
                app.message = "\(number) is in your library. Transcripts will follow."
            } catch is CancellationError {
            } catch {
                importFailure = "\(number): \(error.localizedDescription)"
            }
            importingNumber = nil
            importProgress = nil
            await loadListing()
        }
    }

    private func sync(_ tape: ShelfTape, _ work: @escaping @Sendable (Pusher) async throws -> String) {
        guard !isPushing, let library = app.library, let key = SiteCredentials.load() else {
            if SiteCredentials.load() == nil { syncFailure = "Enter the site’s sync API key first." }
            return
        }
        let pusher = Pusher(library: library, site: SiteClient(baseURL: siteURL, apiKey: key))
        syncingTapeID = tape.id
        lastSyncedTapeID = tape.id
        syncFailure = nil
        syncNote = nil
        progress = nil
        task = Task { [self] in
            do {
                let note = try await work(pusher)
                syncNote = note
                refreshes += 1
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                syncFailure = error.localizedDescription
            }
            syncingTapeID = nil
            progress = nil
        }
    }

    private func finish(tapeID: Int64, result: PushResult) {
        finished = (tapeID, result)
        pushingTapeID = nil
        progress = nil
        app.message = "\(result.catalogNumber) is on the site, unpublished. Publish it from its Site Post."
        joinCollectionOnSite(tapeID: tapeID)
    }

    private func finish(failure: String?) {
        self.failure = failure
        pushingTapeID = nil
        progress = nil
    }
}
