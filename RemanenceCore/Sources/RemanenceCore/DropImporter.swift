import Foundation
import GRDB

public struct DropSummary: Equatable, Sendable {
    public var added: [String] = []
    public var alreadyInLibrary: [String] = []
    public var notAudio: [String] = []
    public var failed: [String] = []
}

/// Adds files dropped on the app. The originals are only ever read. A file becomes
/// one tape, and a folder becomes one tape with a track for each audio file in it.
public struct DropImporter: Sendable {
    public let database: AppDatabase
    public let paths: LibraryPaths
    public let hasModel: @Sendable (String) -> Bool
    public var ffprobe = KnownTools.ffprobe

    public static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "flac", "aiff", "aif", "aac", "ogg", "opus", "caf",
    ]

    /// Numbers the site is using that no tape here has, so new tapes don't take them.
    public var reservedNumbers: Set<String> = []

    public init(database: AppDatabase, paths: LibraryPaths, hasModel: @escaping @Sendable (String) -> Bool) {
        self.database = database
        self.paths = paths
        self.hasModel = hasModel
    }

    public func add(_ urls: [URL]) async -> DropSummary {
        var summary = DropSummary()
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                summary.failed.append("\(url.lastPathComponent): the file couldn’t be found.")
                continue
            }

            let files: [URL]
            let title: String
            let context: String?
            if isFolder.boolValue {
                files = audioFiles(in: url)
                title = url.lastPathComponent
                context = readText(url.appending(path: "context.txt"))
                if files.isEmpty {
                    summary.notAudio.append(url.lastPathComponent)
                    continue
                }
            } else {
                guard Self.isAudio(url) else {
                    summary.notAudio.append(url.lastPathComponent)
                    continue
                }
                files = [url]
                title = Self.readableName(url)
                context = readText(url.appendingPathExtension("context.txt"))
                    ?? readText(url.deletingLastPathComponent().appending(path: "context.txt"))
            }

            await addTape(
                files: files,
                title: title,
                titleIsProvisional: !isFolder.boolValue,
                context: context,
                summary: &summary
            )
        }
        return summary
    }

    private func addTape(
        files: [URL],
        title: String,
        titleIsProvisional: Bool,
        context: String?,
        summary: inout DropSummary
    ) async {
        let uuid = UUID().uuidString
        let folder = paths.masters.appending(path: uuid, directoryHint: .isDirectory)

        struct Copied: Sendable {
            let file: URL
            let sha256: String
            let relativePath: String
            let details: AudioDetails
        }
        var copied: [Copied] = []
        var seen = Set<String>()

        do {
            for file in files {
                let hash = try sha256(of: file)
                let inLibrary = try await database.writer.read { db in
                    try Source.filter(Column("sha256") == hash).fetchCount(db) > 0
                }
                if inLibrary || seen.contains(hash) {
                    summary.alreadyInLibrary.append(file.lastPathComponent)
                    continue
                }
                seen.insert(hash)

                let details: AudioDetails
                do {
                    details = try await probeAudio(file, ffprobe: ffprobe)
                } catch {
                    summary.notAudio.append(file.lastPathComponent)
                    continue
                }

                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = file.lastPathComponent
                let destination = folder.appending(path: name)
                let partial = folder.appending(path: name + ".part")
                try FileManager.default.copyItem(at: file, to: partial)
                guard try sha256(of: partial) == hash else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.moveItem(at: partial, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)

                copied.append(Copied(file: file, sha256: hash, relativePath: "masters/\(uuid)/\(name)", details: details))
            }

            guard !copied.isEmpty else {
                try? FileManager.default.removeItem(at: folder)
                return
            }

            let items = copied
            let model = WhisperModel.preferred(for: .unknown, hasModel: hasModel)
            try await database.writer.write { db in
                let now = Date()
                var tape = Tape(
                    uuid: uuid,
                    title: title,
                    context: context,
                    titleIsProvisional: titleIsProvisional,
                    createdAt: now
                )
                tape.catalogNumber = try Library.nextCatalogNumber(db, excluding: reservedNumbers)
                try tape.insert(db)

                for (position, item) in items.enumerated() {
                    var source = Source(
                        tapeId: tape.id!,
                        position: position,
                        masterPath: item.relativePath,
                        sha256: item.sha256,
                        duration: item.details.duration,
                        sampleRate: item.details.sampleRate,
                        channels: item.details.channels,
                        bitDepth: item.details.bitDepth
                    )
                    try source.insert(db)
                    var track = Track(sourceId: source.id!, name: Self.readableName(item.file))
                    try track.insert(db)
                    try JobStore.enqueuePipeline(db, sourceID: source.id!, trackID: track.id!, model: model, now: now)
                }
                try JobStore.enqueueMissingPeaks(db, now: now)
            }
            summary.added.append(title)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            summary.failed.append("\(title): \(error.localizedDescription)")
        }
    }

    private func audioFiles(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter(Self.isAudio)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func readText(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    static func readableName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
