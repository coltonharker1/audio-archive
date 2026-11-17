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

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var task: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
    }

    var isPushing: Bool { pushingTapeID != nil || syncingTapeID != nil }

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
        app.message = "\(result.catalogNumber) is on the site, unpublished."
    }

    private func finish(failure: String?) {
        self.failure = failure
        pushingTapeID = nil
        progress = nil
    }
}
