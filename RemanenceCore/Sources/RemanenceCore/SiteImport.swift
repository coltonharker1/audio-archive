import Foundation
import GRDB

/// A post on the site, as the site lists them.
public struct SiteEntrySummary: Codable, Equatable, Identifiable, Sendable {
    public let catalogNumber: String
    public let title: String
    public let published: Bool
    public let updatedAt: String
    /// The tape that made it, for posts the app made.
    public let tapeUuid: String?
    public let trackCount: Int
    public let imageCount: Int
    public let duration: Double

    public var id: String { catalogNumber }

    public init(catalogNumber: String, title: String, published: Bool, updatedAt: String, tapeUuid: String? = nil,
                trackCount: Int, imageCount: Int = 0, duration: Double = 0) {
        self.catalogNumber = catalogNumber
        self.title = title
        self.published = published
        self.updatedAt = updatedAt
        self.tapeUuid = tapeUuid
        self.trackCount = trackCount
        self.imageCount = imageCount
        self.duration = duration
    }
}

/// A site post and the tape in this library that holds it, if any.
public struct SiteListing: Identifiable, Equatable, Sendable {
    public let entry: SiteEntrySummary
    public let tapeID: Int64?

    public var id: String { entry.id }
    public var isInLibrary: Bool { tapeID != nil }
}

public enum SiteImportError: LocalizedError, Equatable {
    case alreadyInLibrary(String)
    case noAudio(String)
    case downloadFailed(String)
    case checksumMismatch(String)
    case audioAlreadyInLibrary(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyInLibrary(let number): "\(number) is already in your library."
        case .noAudio(let number): "\(number) has no audio on the site to bring in."
        case .downloadFailed(let name): "Couldn’t download \(name) from the site."
        case .checksumMismatch(let name): "\(name) didn’t download intact. Nothing was added."
        case .audioAlreadyInLibrary(let name): "\(name) is already in your library on another tape, so this post wasn’t brought in."
        }
    }
}

extension Library {
    /// Matches the site's posts with tapes here, by the tape that made them or by
    /// catalog number.
    public func siteListing(_ entries: [SiteEntrySummary]) async throws -> [SiteListing] {
        let tapes = try await database.writer.read { db in
            try Tape.fetchAll(db)
        }
        return entries.map { entry in
            let match = tapes.first { tape in
                if let uuid = entry.tapeUuid, tape.uuid.lowercased() == uuid.lowercased() { return true }
                // A number alone only identifies a tape that's been on the site; a tape
                // not pushed yet holds a number the site may give to something else.
                return tape.pushedAt != nil && tape.catalogNumber == entry.catalogNumber
            }
            return SiteListing(entry: entry, tapeID: match?.id)
        }
    }
}

extension Pusher {
    /// Downloads a file to a local path. Tests stand in for it.
    public typealias FileDownload = @Sendable (URL, URL) async throws -> Void

    public static let downloadFile: FileDownload = { url, destination in
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw SiteImportError.downloadFailed(url.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Brings a post that's only on the site into the library: its best copy of each
    /// track's audio becomes a master, and then everything else is read from the site
    /// as a refresh does. Nothing is added unless every file arrives intact.
    @discardableResult
    public func importEntry(
        catalogNumber: String,
        tapeUUID: String? = nil,
        downloadFile: @escaping FileDownload = Pusher.downloadFile,
        downloadData: @escaping @Sendable (URL) async throws -> Data = Pusher.downloadData,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> Int64 {
        let state = try await site.fetchEntry(tapeUUID: tapeUUID ?? "", catalogNumber: catalogNumber)
        guard !state.tracks.isEmpty else { throw SiteImportError.noAudio(catalogNumber) }
        let uuid = (state.tapeUuid ?? tapeUUID)?.uppercased() ?? UUID().uuidString

        let exists = try await library.database.writer.read { db in
            try Tape.filter(Column("catalog_number") == state.catalogNumber || Column("uuid") == uuid).fetchCount(db) > 0
        }
        guard !exists else { throw SiteImportError.alreadyInLibrary(state.catalogNumber) }

        let folder = library.paths.masters.appending(path: uuid, directoryHint: .isDirectory)
        struct Downloaded: Sendable {
            let path: String
            let sha256: String
            let details: AudioDetails
            let title: String
            let description: String?
        }
        var downloaded: [Downloaded] = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, track) in state.tracks.enumerated() {
                progress(index, state.tracks.count)
                // The download is the lossless original where there is one.
                let source = track.downloadUrl ?? track.audioUrl
                let expected = track.downloadUrl != nil ? track.downloadSha256 : track.audioSha256
                guard let url = URL(string: source), ["https", "http"].contains(url.scheme) else {
                    throw SiteImportError.downloadFailed(track.title)
                }
                let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased()
                let name = Pusher.filename(for: track.title, number: index + 1) + ".\(ext)"
                let destination = folder.appending(path: name)
                let partial = folder.appending(path: name + ".part")
                do {
                    try await downloadFile(url, partial)
                } catch {
                    throw SiteImportError.downloadFailed(track.title)
                }
                let hash = try sha256(of: partial)
                if let expected, expected.lowercased() != hash {
                    throw SiteImportError.checksumMismatch(track.title)
                }
                try FileManager.default.moveItem(at: partial, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)
                downloaded.append(Downloaded(
                    path: "masters/\(uuid)/\(name)",
                    sha256: hash,
                    details: try await probeAudio(destination),
                    title: track.title,
                    description: track.description
                ))
            }
            progress(state.tracks.count, state.tracks.count)

            let items = downloaded
            let now = now()
            let tapeID = try await Task.detached { [library] in
                try await library.database.writer.write { db -> Int64 in
                    for item in items where try Source.filter(Column("sha256") == item.sha256).fetchCount(db) > 0 {
                        throw SiteImportError.audioAlreadyInLibrary(item.title)
                    }
                    var tape = Tape(
                        uuid: uuid,
                        catalogNumber: state.catalogNumber,
                        title: state.title,
                        medium: SiteMedium(rawValue: state.medium)?.label,
                        approvedAt: now,
                        pushedAt: now,
                        createdAt: now
                    )
                    try tape.insert(db)
                    for (position, item) in items.enumerated() {
                        var source = Source(
                            tapeId: tape.id!, position: position, masterPath: item.path, sha256: item.sha256,
                            duration: item.details.duration, sampleRate: item.details.sampleRate,
                            channels: item.details.channels, bitDepth: item.details.bitDepth
                        )
                        try source.insert(db)
                        var track = Track(sourceId: source.id!, name: item.title)
                        track.description = item.description
                        try track.insert(db)
                    }
                    return tape.id!
                }
            }.value

            // Fields, photos, captions and the record of what the site has.
            try await refresh(tapeID: tapeID, download: downloadData)
            return tapeID
        } catch {
            // Never leave files behind for a tape the library doesn't know about.
            let known = try? await library.database.writer.read { db in
                try Tape.filter(Column("uuid") == uuid).fetchCount(db) > 0
            }
            if known != true { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
    }

    /// Publishes or unpublishes a post. Like any update, it's refused if the post
    /// changed on the site since the app last read it.
    public func setPublished(tapeID: Int64, _ published: Bool) async throws {
        let post = try await library.database.writer.read { try Library.fetchPost($0, tapeID: tapeID) }
        guard let post else { throw PushError.nothingToPush }
        guard post.tape.pushedAt != nil else { throw SiteSyncError.notOnSite }
        guard let snapshot = SiteSnapshot.decode(post.tape.siteSnapshot), let expected = post.tape.siteUpdatedAt else {
            throw SiteSyncError.needsRefresh
        }
        var update = SiteUpdate(
            tapeUuid: post.tape.uuid, catalogNumber: post.tape.catalogNumber, expectedUpdatedAt: expected,
            fields: nil, tracks: nil, images: nil
        )
        update.published = published
        let state = try await site.updateEntry(update)
        try await recordSiteState(state, tapeID: tapeID, post: post, previous: snapshot)
    }

    /// Removes a tape's post from the site. The tape stays in the library, as it was
    /// before it was pushed, so it can be pushed again.
    public func deleteFromSite(tapeID: Int64) async throws {
        let tape = try await library.database.writer.read { try Tape.fetchOne($0, key: tapeID) }
        guard let tape, tape.pushedAt != nil else { throw SiteSyncError.notOnSite }
        guard let expected = tape.siteUpdatedAt else { throw SiteSyncError.needsRefresh }
        try await site.deleteEntry(tapeUUID: tape.uuid, catalogNumber: tape.catalogNumber, expectedUpdatedAt: expected)
        try await Task.detached { [library] in
            try await library.database.writer.write { db in
                try db.execute(sql: """
                    UPDATE tape SET catalog_number = NULL, pushed_at = NULL, site_updated_at = NULL, site_snapshot = NULL
                    WHERE id = ?
                    """, arguments: [tapeID])
                try db.execute(sql: "UPDATE tape_image SET site_url = NULL WHERE tape_id = ?", arguments: [tapeID])
            }
        }.value
    }
}
