import Foundation
import GRDB

public struct ImportProgress: Sendable {
    public let tape: String
    public let completedFiles: Int
    public let totalFiles: Int

    public init(tape: String, completedFiles: Int, totalFiles: Int) {
        self.tape = tape
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
    }

    public var fraction: Double {
        totalFiles == 0 ? 0 : Double(completedFiles) / Double(totalFiles)
    }
}

public struct ImportSummary: Equatable, Sendable {
    public let imported: [String]
    public let alreadyInLibrary: [String]
}

public enum ImportError: LocalizedError, Equatable {
    case noManifest
    case badManifest
    case missingCatalogPage(String)
    case catalogMismatch(String)
    case missingFile(String)
    case hashMismatch(String)
    case unaccountedFile(entry: String, file: String)
    case notInManifest(String)

    public var errorDescription: String? {
        switch self {
        case .noManifest: "This folder doesn’t have a manifest.tsv, so it isn’t a Remanence backup."
        case .badManifest: "The backup’s manifest.tsv couldn’t be read."
        case .missingCatalogPage(let entry): "The backup has no catalog page for \(entry)."
        case .catalogMismatch(let entry): "The catalog page for \(entry) describes a different entry."
        case .missingFile(let file): "\(file) is missing from the backup."
        case .hashMismatch(let file): "\(file) doesn’t match its recorded checksum."
        case .unaccountedFile(let entry, let file): "\(file) in \(entry) isn’t listed on its catalog page."
        case .notInManifest(let file): "\(file) is on a catalog page but not in the manifest."
        }
    }
}

/// Imports a backup of the site's audio into the library.
///
/// The backup is only ever read. Each file's copy is checked against its recorded
/// checksum, and a tape is added only once all its files check out. A tape already
/// in the library is skipped, so an interrupted import can simply be run again.
public struct BackupImporter: Sendable {
    public let database: AppDatabase
    public let paths: LibraryPaths

    public init(database: AppDatabase, paths: LibraryPaths) {
        self.database = database
        self.paths = paths
    }

    public func run(
        from backup: URL,
        progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportSummary {
        let manifest = try Self.readManifest(in: backup)
        let entries = manifest.keys.sorted()
        let totalFiles = manifest.values.reduce(0) { $0 + $1.count }

        // Read every page first, so a bad backup fails before anything is copied.
        var pages: [String: CatalogPage] = [:]
        for entry in entries {
            let pageURL = backup.appending(path: "catalog-pages/\(entry).html")
            guard let html = try? String(contentsOf: pageURL, encoding: .utf8) else {
                throw ImportError.missingCatalogPage(entry)
            }
            let page = try CatalogPage(html: html)
            guard page.catalogNumber == entry else { throw ImportError.catalogMismatch(entry) }
            try Self.checkFilesMatch(page: page, files: manifest[entry] ?? [], entry: entry)
            pages[entry] = page
        }

        var imported: [String] = []
        var skipped: [String] = []
        var completed = 0

        for entry in entries {
            guard let page = pages[entry], let files = manifest[entry] else { continue }
            let exists = try await database.writer.read { db in
                try Tape.filter(Column("catalog_number") == entry).fetchCount(db) > 0
            }
            if exists {
                skipped.append(entry)
            } else {
                try await importTape(page: page, files: files, backup: backup) {
                    completed += 1
                    progress(ImportProgress(tape: page.title, completedFiles: completed, totalFiles: totalFiles))
                }
                imported.append(entry)
                continue
            }
            completed += files.count
            progress(ImportProgress(tape: page.title, completedFiles: completed, totalFiles: totalFiles))
        }

        return ImportSummary(imported: imported, alreadyInLibrary: skipped)
    }

    private func importTape(
        page: CatalogPage,
        files: [ManifestFile],
        backup: URL,
        fileCopied: () -> Void
    ) async throws {
        let entry = page.catalogNumber
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0) })
        let masterDirectory = paths.masters.appending(path: entry, directoryHint: .isDirectory)
        let prepDirectory = paths.processed.appending(path: entry, directoryHint: .isDirectory)

        do {
            try FileManager.default.createDirectory(at: masterDirectory, withIntermediateDirectories: true)

            struct Prepared: Sendable {
                let track: CatalogPage.Track
                let masterPath: String
                let prepPath: String?
                let sha256: String
                let details: AudioDetails
            }
            var collected: [Prepared] = []

            for track in page.tracks {
                // Where a track has a separate download, that's the master and the
                // streaming file is the processed copy. Otherwise it's the only file.
                let masterName = track.downloadFile ?? track.audioFile
                guard let master = byName[masterName] else { throw ImportError.notInManifest(masterName) }

                let masterURL = masterDirectory.appending(path: masterName)
                try copyVerified(master, in: backup, entry: entry, to: masterURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: masterURL.path)
                fileCopied()

                var prepPath: String?
                if track.downloadFile != nil {
                    guard let prep = byName[track.audioFile] else { throw ImportError.notInManifest(track.audioFile) }
                    try FileManager.default.createDirectory(at: prepDirectory, withIntermediateDirectories: true)
                    try copyVerified(prep, in: backup, entry: entry, to: prepDirectory.appending(path: prep.name))
                    prepPath = "processed/\(entry)/\(prep.name)"
                    fileCopied()
                }

                collected.append(Prepared(
                    track: track,
                    masterPath: "masters/\(entry)/\(masterName)",
                    prepPath: prepPath,
                    sha256: master.sha256,
                    details: try await probeAudio(masterURL)
                ))
            }

            let prepared = collected
            let pushedAt = files.compactMap(\.lastModified).max()
            let now = Date()
            try await database.writer.write { db in
                var tape = Tape(
                    uuid: UUID().uuidString,
                    catalogNumber: entry,
                    title: page.title,
                    medium: page.medium,
                    era: page.era,
                    description: page.description.isEmpty ? nil : page.description,
                    pushedAt: pushedAt ?? now,
                    createdAt: now
                )
                try tape.insert(db)

                for (position, item) in prepared.enumerated() {
                    var source = Source(
                        tapeId: tape.id!,
                        position: position,
                        masterPath: item.masterPath,
                        sha256: item.sha256,
                        prepPath: item.prepPath,
                        duration: item.details.duration,
                        sampleRate: item.details.sampleRate,
                        channels: item.details.channels,
                        bitDepth: item.details.bitDepth
                    )
                    try source.insert(db)
                    var track = Track(sourceId: source.id!, name: item.track.title)
                    try track.insert(db)
                }
            }
        } catch {
            // Never leave files behind for a tape the library doesn't know about.
            try? FileManager.default.removeItem(at: masterDirectory)
            try? FileManager.default.removeItem(at: prepDirectory)
            throw error
        }
    }

    private func copyVerified(_ file: ManifestFile, in backup: URL, entry: String, to destination: URL) throws {
        let source = backup.appending(path: "\(entry)/\(file.name)")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ImportError.missingFile("\(entry)/\(file.name)")
        }
        try? FileManager.default.removeItem(at: destination)

        let partial = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.copyItem(at: source, to: partial)

        guard try sha256(of: partial) == file.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw ImportError.hashMismatch("\(entry)/\(file.name)")
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    struct ManifestFile: Sendable {
        let name: String
        let sha256: String
        let lastModified: Date?
    }

    static func readManifest(in backup: URL) throws -> [String: [ManifestFile]] {
        let url = backup.appending(path: "manifest.tsv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ImportError.noManifest }

        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.split(separator: "\t", omittingEmptySubsequences: false).map(String.init),
              let entryColumn = header.firstIndex(of: "entry"),
              let fileColumn = header.firstIndex(of: "file"),
              let hashColumn = header.firstIndex(of: "sha256") else {
            throw ImportError.badManifest
        }
        let dateColumn = header.firstIndex(of: "last_modified")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        var entries: [String: [ManifestFile]] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count > max(entryColumn, fileColumn, hashColumn), fields[hashColumn].count == 64 else {
                throw ImportError.badManifest
            }
            let date = dateColumn.flatMap { $0 < fields.count ? formatter.date(from: fields[$0]) : nil }
            entries[fields[entryColumn], default: []].append(
                ManifestFile(name: fields[fileColumn], sha256: fields[hashColumn], lastModified: date)
            )
        }
        guard !entries.isEmpty else { throw ImportError.badManifest }
        return entries
    }

    /// Fails if a backed-up file wouldn't end up in the library. Losing track of
    /// audio silently is the worst thing an import could do.
    private static func checkFilesMatch(page: CatalogPage, files: [ManifestFile], entry: String) throws {
        let referenced = Set(page.tracks.flatMap { [$0.audioFile, $0.downloadFile].compactMap(\.self) })
        for file in files where !referenced.contains(file.name) {
            throw ImportError.unaccountedFile(entry: entry, file: file.name)
        }
        let listed = Set(files.map(\.name))
        for name in referenced where !listed.contains(name) {
            throw ImportError.notInManifest(name)
        }
    }
}
