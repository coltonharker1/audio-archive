import Foundation

/// Where tests put their files: one folder per test process, removed when it exits.
enum TestFolders {
    /// `$TMPDIR/remanence-tests/<pid>-<uuid>/`, made once per test process.
    static let runRoot: URL = {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "remanence-tests", directoryHint: .isDirectory)
        removeDeadRuns(in: parent)
        let root = parent.appending(path: "\(getpid())-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Not until exit, so no test can still have a database open in here.
        atexit { try? FileManager.default.removeItem(at: TestFolders.runRoot) }
        return root
    }()

    /// A new, empty folder for one test.
    static func make(_ name: String) throws -> URL {
        let folder = runRoot.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A new path for one loose file, ending in `name`. Nothing is created.
    static func file(_ name: String) -> URL {
        runRoot.appending(path: "\(UUID().uuidString)-\(name)", directoryHint: .notDirectory)
    }

    /// Removes run folders left by test processes that were killed or crashed.
    /// `kill(pid, 0)` failing with ESRCH means the process no longer exists. Anything
    /// not named like a run folder is left alone.
    private static func removeDeadRuns(in parent: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names {
            let parts = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].allSatisfy({ ("0"..."9").contains($0) }),
                  let pid = pid_t(parts[0]), pid > 0,
                  UUID(uuidString: String(parts[1])) != nil,
                  kill(pid, 0) == -1, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: parent.appending(path: name))
        }
    }
}
