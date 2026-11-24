import Foundation
import GRDB

/// A post as the site has it now.
public struct SitePostState: Codable, Equatable, Sendable {
    public struct Track: Codable, Equatable, Sendable {
        public let title: String
        public let description: String?
        public let duration: Double?
        public let audioUrl: String
        public let downloadUrl: String?
        public let audioSha256: String?
        public let downloadSha256: String?

        public init(title: String, description: String? = nil, duration: Double? = nil, audioUrl: String,
                    downloadUrl: String? = nil, audioSha256: String? = nil, downloadSha256: String? = nil) {
            self.title = title
            self.description = description
            self.duration = duration
            self.audioUrl = audioUrl
            self.downloadUrl = downloadUrl
            self.audioSha256 = audioSha256
            self.downloadSha256 = downloadSha256
        }
    }

    public struct Image: Codable, Equatable, Sendable {
        public let url: String
        public let filename: String?
        public let caption: String?
        public let sha256: String?

        public init(url: String, filename: String? = nil, caption: String? = nil, sha256: String? = nil) {
            self.url = url
            self.filename = filename
            self.caption = caption
            self.sha256 = sha256
        }
    }

    /// The tape that made the post, for posts the app made.
    public var tapeUuid: String? = nil
    public let catalogNumber: String
    public let title: String
    public let description: String?
    public let medium: String
    public let whereFound: String?
    public let dateFound: String?
    public let estimatedRecordingDate: String?
    public let published: Bool
    public let updatedAt: String
    public let tracks: [Track]
    public let images: [Image]

    public init(catalogNumber: String, title: String, description: String? = nil, medium: String,
                whereFound: String? = nil, dateFound: String? = nil, estimatedRecordingDate: String? = nil,
                published: Bool = false, updatedAt: String, tracks: [Track] = [], images: [Image] = []) {
        self.catalogNumber = catalogNumber
        self.title = title
        self.description = description
        self.medium = medium
        self.whereFound = whereFound
        self.dateFound = dateFound
        self.estimatedRecordingDate = estimatedRecordingDate
        self.published = published
        self.updatedAt = updatedAt
        self.tracks = tracks
        self.images = images
    }
}

/// What the site had when the app last read or wrote the post, tied to the app's own
/// tracks and photos. Changes are worked out against this.
public struct SiteSnapshot: Codable, Equatable, Sendable {
    public struct Fields: Codable, Equatable, Sendable {
        public var title: String
        public var description: String?
        public var medium: String
        public var whereFound: String?
        public var dateFound: String?
        public var estimatedRecordingDate: String?
    }

    public struct Track: Codable, Equatable, Sendable {
        public var sourceID: Int64
        public var startMarkerID: Int64?
        public var start: Double
        public var end: Double
        /// A file of the track the site knows by hash, which is how it finds the track.
        /// Nil when the site can't identify it, so its text can't be changed from here.
        public var sha256: String?
        public var title: String
        public var description: String?
    }

    public struct Image: Codable, Equatable, Sendable {
        public var url: String
        public var caption: String?
    }

    public var published: Bool
    public var fields: Fields
    public var tracks: [Track]
    public var images: [Image]

    public static func decode(_ json: String?) -> SiteSnapshot? {
        json.flatMap { try? JSONDecoder().decode(SiteSnapshot.self, from: Data($0.utf8)) }
    }

    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}

/// What an update would send.
public struct SiteChanges: Equatable, Sendable {
    public struct Fields: Encodable, Equatable, Sendable {
        public var title: String?
        public var description: String??
        public var medium: String?
        public var whereFound: String??
        public var dateFound: String??
        public var estimatedRecordingDate: String??

        public var isEmpty: Bool { names.isEmpty }

        public var names: [String] {
            var names: [String] = []
            if title != nil { names.append("Title") }
            if medium != nil { names.append("Medium") }
            if estimatedRecordingDate != nil { names.append("Recording date") }
            if whereFound != nil { names.append("Where found") }
            if dateFound != nil { names.append("Date acquired") }
            if description != nil { names.append("Description") }
            return names
        }

        // A field that's cleared is sent as null. One that isn't changing is left out.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(medium, forKey: .medium)
            for (key, value) in [(CodingKeys.description, description), (.whereFound, whereFound),
                                 (.dateFound, dateFound), (.estimatedRecordingDate, estimatedRecordingDate)] {
                if let value { try container.encode(value, forKey: key) }
            }
        }

        enum CodingKeys: String, CodingKey {
            case title, description, medium, whereFound, dateFound, estimatedRecordingDate
        }
    }

    public struct TrackText: Encodable, Equatable, Sendable {
        public let sha256: String
        public var title: String?
        public var description: String??
        let label: String

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sha256, forKey: .sha256)
            try container.encodeIfPresent(title, forKey: .title)
            if let description { try container.encode(description, forKey: .description) }
        }

        enum CodingKeys: String, CodingKey { case sha256, title, description }
    }

    /// A photo in the new list: one already on the site by its URL, or a new upload.
    public struct Image: Encodable, Equatable, Sendable {
        public var url: String?
        public var sha256: String?
        public var filename: String?
        public var caption: String?
    }

    public var fields = Fields()
    public var tracks: [TrackText] = []
    public var images: [Image]?
    /// Changes the site can't take this way, explained.
    public var notSent: [String] = []

    public var isEmpty: Bool { fields.isEmpty && tracks.isEmpty && images == nil }

    /// The changes in a few words, for the screen.
    public var summary: [String] {
        fields.names + tracks.map(\.label) + (images == nil ? [] : ["Photos"])
    }
}

private func blankToNil(_ text: String?) -> String? {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

extension SiteChanges {
    /// Compares the post as written here with what the site had.
    public static func between(_ post: SitePost, and snapshot: SiteSnapshot) -> SiteChanges {
        var changes = SiteChanges()
        let tape = post.tape
        let fields = snapshot.fields

        if let title = blankToNil(tape.title), title != fields.title { changes.fields.title = title }
        if let medium = SiteMedium(label: tape.medium)?.rawValue, medium != fields.medium { changes.fields.medium = medium }
        func compare(_ local: String?, _ site: String?) -> String?? {
            blankToNil(local) == blankToNil(site) ? nil : .some(blankToNil(local))
        }
        changes.fields.description = compare(tape.description, fields.description)
        changes.fields.whereFound = compare(post.whereFound, fields.whereFound)
        changes.fields.dateFound = compare(post.dateFound, fields.dateFound)
        changes.fields.estimatedRecordingDate = compare(tape.era, fields.estimatedRecordingDate)

        let local = Dictionary(post.tracks.map { (TrackKey($0.sourceID, $0.startMarkerID), $0) }, uniquingKeysWith: { first, _ in first })
        for (index, sent) in snapshot.tracks.enumerated() {
            let label = "Track \(index + 1)"
            guard let track = local[TrackKey(sent.sourceID, sent.startMarkerID)] else {
                changes.notSent.append("\(sent.title) is no longer a track here. Removing tracks isn’t possible from the app yet.")
                continue
            }
            if abs(track.start - sent.start) > 0.01 || abs(track.end - sent.end) > 0.01 {
                changes.notSent.append("\(sent.title)’s audio has changed since it went to the site. Replacing audio isn’t possible from the app yet.")
                continue
            }
            let title = blankToNil(track.name) ?? (post.tracks.count == 1 ? tape.title : sent.title)
            var text = TrackText(sha256: sent.sha256 ?? "", label: label)
            if title != sent.title { text.title = title }
            text.description = compare(track.description, sent.description)
            guard text.title != nil || text.description != nil else { continue }
            guard sent.sha256 != nil else {
                changes.notSent.append("\(sent.title) can’t be matched to its track on the site, so its text can’t be changed from here.")
                continue
            }
            changes.tracks.append(text)
        }
        let known = Set(snapshot.tracks.map { TrackKey($0.sourceID, $0.startMarkerID) })
        for track in post.tracks where !known.contains(TrackKey(track.sourceID, track.startMarkerID)) {
            changes.notSent.append("\(track.name ?? "A new track") isn’t on the site. Adding tracks isn’t possible from the app yet.")
        }

        let desired = post.images.map { image in
            image.siteUrl.map { Image(url: $0, caption: blankToNil(image.caption)) }
                ?? Image(sha256: image.sha256, filename: image.filename, caption: blankToNil(image.caption))
        }
        let current = snapshot.images.map { Image(url: $0.url, caption: blankToNil($0.caption)) }
        if desired != current { changes.images = desired }
        return changes
    }
}

struct TrackKey: Hashable {
    let sourceID: Int64
    let startMarkerID: Int64?

    init(_ sourceID: Int64, _ startMarkerID: Int64?) {
        self.sourceID = sourceID
        self.startMarkerID = startMarkerID
    }
}

extension SiteSnapshot {
    /// Ties the site's post to this tape's tracks. A track is matched by a file the site
    /// knows by hash: the one the app last used for it, or for tapes that came from the
    /// site, the master the import was made from. If none match but the counts agree,
    /// tracks are matched in order, since that's how they were imported.
    static func matchTracks(
        _ state: SitePostState,
        to post: SitePost,
        previous: SiteSnapshot?,
        masterHashes: [Int64: String]
    ) -> [TrackKey: (index: Int, sha256: String?)] {
        let previousSha = Dictionary(
            (previous?.tracks ?? []).map { (TrackKey($0.sourceID, $0.startMarkerID), $0.sha256) },
            uniquingKeysWith: { first, _ in first }
        )
        var matches: [TrackKey: (Int, String?)] = [:]
        var used = Set<Int>()
        for track in post.tracks {
            let key = TrackKey(track.sourceID, track.startMarkerID)
            let candidates = [previousSha[key] ?? nil, track.startMarkerID == nil ? masterHashes[track.sourceID] : nil].compactMap(\.self)
            for sha in candidates {
                if let index = state.tracks.firstIndex(where: { $0.audioSha256 == sha || $0.downloadSha256 == sha }), !used.contains(index) {
                    matches[key] = (index, sha)
                    used.insert(index)
                    break
                }
            }
        }
        if matches.isEmpty, state.tracks.count == post.tracks.count {
            for (index, track) in post.tracks.enumerated() {
                let site = state.tracks[index]
                matches[TrackKey(track.sourceID, track.startMarkerID)] = (index, site.audioSha256 ?? site.downloadSha256)
            }
        }
        return matches
    }

    static func make(from state: SitePostState, post: SitePost, matches: [TrackKey: (index: Int, sha256: String?)]) -> SiteSnapshot {
        let tracks = post.tracks.compactMap { track -> Track? in
            guard let match = matches[TrackKey(track.sourceID, track.startMarkerID)] else { return nil }
            let site = state.tracks[match.index]
            return Track(
                sourceID: track.sourceID, startMarkerID: track.startMarkerID,
                start: track.start, end: track.end, sha256: match.sha256,
                title: site.title, description: blankToNil(site.description)
            )
        }
        return SiteSnapshot(
            published: state.published,
            fields: Fields(
                title: state.title, description: blankToNil(state.description), medium: state.medium,
                whereFound: blankToNil(state.whereFound), dateFound: blankToNil(state.dateFound),
                estimatedRecordingDate: blankToNil(state.estimatedRecordingDate)
            ),
            tracks: tracks,
            images: state.images.map { Image(url: $0.url, caption: blankToNil($0.caption)) }
        )
    }
}

public enum SiteSyncError: LocalizedError, Equatable {
    case notOnSite
    case needsRefresh
    case photoDownloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notOnSite: "This tape isn’t on the site yet."
        case .needsRefresh: "Refresh from the site first, so the app knows what it has now."
        case .photoDownloadFailed(let url): "Couldn’t download the photo at \(url)."
        }
    }
}

public struct RefreshResult: Equatable, Sendable {
    public let unmatchedTracks: Int
    public let photosSkipped: [String]
}

extension Library {
    /// Saves what the site has, after a push, pull or update.
    func saveSiteState(tapeID: Int64, _ state: SitePostState, snapshot: SiteSnapshot) async throws {
        try await Task.detached { [database] in
            try await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE tape SET catalog_number = ?, site_updated_at = ?, site_snapshot = ? WHERE id = ?",
                    arguments: [state.catalogNumber, state.updatedAt, snapshot.encoded, tapeID]
                )
            }
        }.value
    }

    fileprivate func masterHashes(tapeID: Int64) async throws -> [Int64: String] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, sha256 FROM source WHERE tape_id = ? AND sha256 IS NOT NULL", arguments: [tapeID])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0["sha256"] as String) })
        }
    }

    fileprivate func currentPost(_ tapeID: Int64) async throws -> SitePost {
        guard let post = try await database.writer.read({ try Self.fetchPost($0, tapeID: tapeID) }) else {
            throw PushError.nothingToPush
        }
        return post
    }
}

extension Pusher {
    /// Loads the post as the site has it now, replacing what's written here. Photos on
    /// the site are downloaded. Ones added here and not sent yet are kept.
    @discardableResult
    public func refresh(tapeID: Int64, download: @escaping @Sendable (URL) async throws -> Data = Pusher.downloadData) async throws -> RefreshResult {
        let post = try await library.currentPost(tapeID)
        guard post.tape.pushedAt != nil else { throw SiteSyncError.notOnSite }
        let state = try await site.fetchEntry(tapeUUID: post.tape.uuid, catalogNumber: post.tape.catalogNumber)
        let previous = SiteSnapshot.decode(post.tape.siteSnapshot)
        let matches = SiteSnapshot.matchTracks(state, to: post, previous: previous, masterHashes: try await library.masterHashes(tapeID: tapeID))

        // Photos first, since downloads can fail and nothing should change if one does
        // partway. A failed photo is skipped and reported instead.
        var skipped: [String] = []
        var downloaded: [String: URL] = [:]
        let folder = library.paths.images.appending(path: post.tape.uuid, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for image in state.images where !post.images.contains(where: { $0.siteUrl == image.url }) {
            guard let url = URL(string: image.url), ["https", "http"].contains(url.scheme) else {
                skipped.append(image.url)
                continue
            }
            do {
                let data = try await download(url)
                let name = url.lastPathComponent.isEmpty ? "photo" : url.lastPathComponent
                let temporary = FileManager.default.temporaryDirectory.appending(path: "remanence-\(UUID().uuidString)-\(name)")
                try data.write(to: temporary)
                defer { try? FileManager.default.removeItem(at: temporary) }
                downloaded[image.url] = try Library.prepareImage(temporary, in: folder).url
            } catch {
                skipped.append(image.url)
            }
        }

        let snapshot = SiteSnapshot.make(from: state, post: post, matches: matches)
        let library = library
        let uuid = post.tape.uuid
        let downloads = downloaded
        let removedPaths: [String] = try await Task.detached {
            try await library.database.writer.write { db -> [String] in
                guard var tape = try Tape.fetchOne(db, key: tapeID) else { return [] }
                tape.title = state.title
                tape.titleIsProvisional = false
                tape.description = blankToNil(state.description)
                tape.medium = SiteMedium(rawValue: state.medium)?.label ?? tape.medium
                tape.era = blankToNil(state.estimatedRecordingDate)
                // What the site has from the collection stays the collection's.
                func own(_ site: String?, inherited: String?, current: String?) -> String? {
                    let site = blankToNil(site)
                    return current == nil && site != nil && site == inherited ? nil : site
                }
                tape.whereFound = own(state.whereFound, inherited: post.collection?.whereFound, current: tape.whereFound)
                tape.dateFound = own(state.dateFound, inherited: post.collection?.dateFound, current: tape.dateFound)
                tape.catalogNumber = state.catalogNumber
                tape.siteUpdatedAt = state.updatedAt
                tape.siteSnapshot = snapshot.encoded
                try tape.update(db)

                for track in post.tracks {
                    guard let match = matches[TrackKey(track.sourceID, track.startMarkerID)] else { continue }
                    let site = state.tracks[match.index]
                    var row = try Track
                        .filter(Column("source_id") == track.sourceID)
                        .filter(track.startMarkerID == nil ? Column("start_marker_id") == nil : Column("start_marker_id") == track.startMarkerID)
                        .fetchOne(db) ?? Track(sourceId: track.sourceID, startMarkerId: track.startMarkerID)
                    // A lone track takes the post's title unless it was named differently.
                    row.name = post.tracks.count == 1 && site.title == state.title ? row.name : site.title
                    row.description = blankToNil(site.description)
                    try row.save(db)
                }

                // The site's photos, in its order, then any added here and not sent yet.
                var images = try TapeImage.filter(Column("tape_id") == tapeID).fetchAll(db)
                var removed: [String] = []
                for image in images where image.siteUrl != nil && !state.images.contains(where: { $0.url == image.siteUrl }) {
                    try image.delete(db)
                    removed.append(image.path)
                }
                images.removeAll { image in removed.contains(image.path) }
                var position = 0
                for siteImage in state.images {
                    if var existing = images.first(where: { $0.siteUrl == siteImage.url }) {
                        existing.position = position
                        existing.caption = blankToNil(siteImage.caption)
                        try existing.update(db)
                    } else if let file = downloads[siteImage.url] {
                        let hash = file.deletingPathExtension().lastPathComponent
                        if var same = images.first(where: { $0.sha256 == hash }) {
                            same.siteUrl = siteImage.url
                            same.position = position
                            same.caption = blankToNil(siteImage.caption)
                            try same.update(db)
                        } else {
                            var image = TapeImage(
                                tapeId: tapeID, position: position, path: "images/\(uuid)/\(file.lastPathComponent)",
                                sha256: hash, filename: siteImage.filename ?? file.lastPathComponent,
                                caption: blankToNil(siteImage.caption), siteUrl: siteImage.url
                            )
                            try image.insert(db)
                        }
                    } else {
                        continue
                    }
                    position += 1
                }
                for var image in try TapeImage.filter(Column("tape_id") == tapeID && Column("site_url") == nil).order(Column("position")).fetchAll(db) {
                    image.position = position
                    try image.update(db)
                    position += 1
                }
                return removed
            }
        }.value
        for path in removedPaths { try? FileManager.default.removeItem(at: try library.url(forLibraryPath: path)) }

        return RefreshResult(unmatchedTracks: post.tracks.count - matches.count, photosSkipped: skipped)
    }

    public static let downloadData: @Sendable (URL) async throws -> Data = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SiteSyncError.photoDownloadFailed(url.absoluteString) }
        return data
    }

    /// What an update would change, or nil if the app doesn't know the site's state yet.
    public static func changes(for post: SitePost) -> SiteChanges? {
        SiteSnapshot.decode(post.tape.siteSnapshot).map { SiteChanges.between(post, and: $0) }
    }

    /// Sends what's changed here since the app last read or wrote the post. The site
    /// refuses if the post changed there in the meantime.
    @discardableResult
    public func update(tapeID: Int64, progress: @escaping @Sendable (PushProgress) -> Void = { _ in }) async throws -> SiteChanges {
        let post = try await library.currentPost(tapeID)
        guard post.tape.pushedAt != nil else { throw SiteSyncError.notOnSite }
        guard let snapshot = SiteSnapshot.decode(post.tape.siteSnapshot), let expected = post.tape.siteUpdatedAt else {
            throw SiteSyncError.needsRefresh
        }
        let changes = SiteChanges.between(post, and: snapshot)
        guard !changes.isEmpty else { return changes }

        // New photos are uploaded first, as for a push.
        let newImages = post.images.filter { $0.siteUrl == nil }
        if changes.images != nil, !newImages.isEmpty {
            progress(.checking)
            let files = try newImages.map { image in
                let url = try library.url(forLibraryPath: image.path)
                return try describe(url, filename: image.filename, contentType: url.pathExtension == "png" ? "image/png" : "image/jpeg", kind: .image)
            }
            let existing = try await site.existingFiles(files.map(\.sha256))
            let missing = files.filter { !existing.contains($0.sha256) }
            for (index, file) in missing.enumerated() {
                try await send(file) { fraction in progress(.uploading(file: index + 1, of: missing.count, fraction: fraction)) }
            }
        }

        progress(.creating)
        let state = try await site.updateEntry(SiteUpdate(
            tapeUuid: post.tape.uuid,
            catalogNumber: post.tape.catalogNumber,
            expectedUpdatedAt: expected,
            fields: changes.fields.isEmpty ? nil : changes.fields,
            tracks: changes.tracks.isEmpty ? nil : changes.tracks,
            images: changes.images
        ))
        try await recordSiteState(state, tapeID: tapeID, post: post, previous: snapshot)
        return changes
    }

    /// Saves the site's answer, and links new photos to their URLs on the site.
    func recordSiteState(_ state: SitePostState, tapeID: Int64, post: SitePost, previous: SiteSnapshot?) async throws {
        let matches = SiteSnapshot.matchTracks(state, to: post, previous: previous, masterHashes: try await library.masterHashes(tapeID: tapeID))
        let snapshot = SiteSnapshot.make(from: state, post: post, matches: matches)
        let links = post.images.enumerated().compactMap { index, image -> (Int64, String)? in
            guard image.siteUrl == nil, let id = image.id else { return nil }
            if let site = state.images.first(where: { $0.sha256 == image.sha256 }) { return (id, site.url) }
            // Without hashes, the site's list is in the order it was sent.
            return state.images.indices.contains(index) && state.images.count == post.images.count ? (id, state.images[index].url) : nil
        }
        let library = library
        try await Task.detached {
            try await library.database.writer.write { db in
                for (id, url) in links {
                    try db.execute(sql: "UPDATE tape_image SET site_url = ? WHERE id = ?", arguments: [url, id])
                }
                try db.execute(
                    sql: "UPDATE tape SET catalog_number = ?, site_updated_at = ?, site_snapshot = ? WHERE id = ?",
                    arguments: [state.catalogNumber, state.updatedAt, snapshot.encoded, tapeID]
                )
            }
        }.value
    }
}

/// The body of an update.
public struct SiteUpdate: Encodable, Equatable, Sendable {
    public let tapeUuid: String
    public let catalogNumber: String?
    public let expectedUpdatedAt: String
    public let fields: SiteChanges.Fields?
    public let tracks: [SiteChanges.TrackText]?
    public let images: [SiteChanges.Image]?
    public var published: Bool? = nil
}
