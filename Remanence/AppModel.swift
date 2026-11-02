import Foundation
import Observation
import RemanenceCore

@MainActor
@Observable
final class AppModel {
    let paths = LibraryPaths.standard
    let requirements: [Requirement]

    private(set) var states: [Requirement.ID: RequirementState] = [:]
    private(set) var downloads: [Requirement.ID: Double] = [:]
    private(set) var downloadErrors: [Requirement.ID: String] = [:]
    private(set) var hasChecked = false
    private(set) var database: AppDatabase?
    private(set) var databaseError: String?

    init() {
        requirements = SetupCatalog.requirements(paths: paths)
        do {
            try paths.createDirectories()
            database = try AppDatabase.open(at: paths.database)
        } catch {
            databaseError = error.localizedDescription
        }
    }

    var isReady: Bool {
        hasChecked && requirements.allSatisfy { $0.isOptional || states[$0.id] == .ready }
    }

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
}
