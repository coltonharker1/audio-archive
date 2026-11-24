import CryptoKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

/// The formats the site knows, with the names this app shows for them.
public enum SiteMedium: String, CaseIterable, Identifiable, Sendable {
    case reel5 = "reel-to-reel-5"
    case reel7 = "reel-to-reel-7"
    case reel10 = "reel-to-reel-10"
    case reel = "reel-to-reel"
    case cassette
    case eightTrack = "8-track"
    case vinyl
    case microcassette
    case wire = "wire-recording"
    case minidisc
    case dat
    case other

    public var id: String { rawValue }

    /// Matches the labels in the site's admin.
    public var label: String {
        switch self {
        case .reel5: "5\" Reel-to-Reel"
        case .reel7: "7\" Reel-to-Reel"
        case .reel10: "10\" Reel-to-Reel"
        case .reel: "Reel-to-Reel"
        case .cassette: "Cassette"
        case .eightTrack: "8-Track"
        case .vinyl: "Vinyl"
        case .microcassette: "Microcassette"
        case .wire: "Wire Recording"
        case .minidisc: "MiniDisc"
        case .dat: "DAT"
        case .other: "Other"
        }
    }

    /// Reads the names stored on tapes, which are the labels above.
    public init?(label: String?) {
        let text = (label ?? "").lowercased()
        if let exact = Self.allCases.first(where: { $0.label.lowercased() == text }) {
            self = exact
            return
        }
        if text.contains("micro") { self = .microcassette }
        else if text.contains("cassette") { self = .cassette }
        else if text.contains("8-track") || text.contains("8 track") { self = .eightTrack }
        else if text.contains("reel") {
            if text.contains("10\"") { self = .reel10 }
            else if text.contains("7\"") { self = .reel7 }
            else if text.contains("5\"") { self = .reel5 }
            else { self = .reel }
        }
        else if text.contains("vinyl") { self = .vinyl }
        else if text.contains("wire") { self = .wire }
        else if text.contains("minidisc") { self = .minidisc }
        else if text == "dat" { self = .dat }
        else { return nil }
    }
}

/// One track of a post, with what's written for it and Claude's summary as reference.
public struct PostTrack: Identifiable, Equatable, Sendable {
    public let sourceID: Int64
    public let startMarkerID: Int64?
    public let name: String?
    public let description: String?
    public let start: Double
    public let end: Double
    public let summaryShort: String?
    public let summaryLong: String?
    public var estimatedEra: String? = nil
    public var adjustments: TrackAdjustments = .none
    /// The stored track row, when there is one.
    public var trackID: Int64? = nil
    /// Tracks appended to this one, in the order they play after it. Each keeps its
    /// own level, speed and direction.
    public var continuations: [PostTrack] = []
    /// Master seconds left out at each end, in recording order. `start` and `end`
    /// are what's kept; the whole stretch runs from `start - cutStart`.
    public var cutStart: Double = 0
    public var cutEnd: Double = 0
    public var spanStart: Double { start - cutStart }
    public var spanEnd: Double { end + cutEnd }
    public var isCut: Bool { cutStart > 0 || cutEnd > 0 }

    public var id: String { "\(sourceID)-\(startMarkerID ?? 0)" }
    /// How long this piece plays on its own, at its adjusted speed.
    public var pieceDuration: Double { adjustments.duration(of: end - start) }
    /// How long it plays, at its adjusted speed, with anything appended to it.
    public var duration: Double { pieceDuration + continuations.reduce(0) { $0 + $1.pieceDuration } }
    /// This track and everything appended to it, each as a piece on its own.
    public var pieces: [PostTrack] {
        var head = self
        head.continuations = []
        return [head] + continuations
    }
}

/// Everything the site will show for a tape.
public struct SitePost: Equatable, Sendable {
    public let tape: Tape
    public let tracks: [PostTrack]
    public let images: [TapeImage]
    /// The collection the tape came in, if any.
    public var collection: TapeCollection? = nil

    /// Where and when it was found: its own, or else its collection's.
    public var whereFound: String? { tape.whereFound ?? collection?.whereFound }
    public var dateFound: String? { tape.dateFound ?? collection?.dateFound }

    /// Claude's guess at when it was recorded.
    public var eraReference: String? {
        tracks.lazy.compactMap(\.estimatedEra).first { !$0.isEmpty }
    }

    /// Claude's description of the whole tape, to write from.
    public var summaryReference: String? {
        let summarized = tracks.filter { $0.summaryLong?.isEmpty == false }
        if summarized.count == 1, tracks.count == 1 { return summarized[0].summaryLong }
        let lines = tracks.enumerated().compactMap { index, track -> String? in
            guard let short = track.summaryShort, !short.isEmpty else { return nil }
            return "\(track.name ?? "Track \(index + 1)"): \(short)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }
}

/// The fields of a post that are a single line or block of text.
public struct PostFields: Equatable, Sendable {
    public var title: String
    public var description: String
    public var medium: SiteMedium?
    public var recordedDate: String
    public var whereFound: String
    public var dateFound: String

    public init(tape: Tape) {
        title = tape.title
        description = tape.description ?? ""
        medium = SiteMedium(label: tape.medium)
        recordedDate = tape.era ?? ""
        whereFound = tape.whereFound ?? ""
        dateFound = tape.dateFound ?? ""
    }
}

public enum ImageImportError: LocalizedError, Equatable {
    case unreadable(String)
    case alreadyAdded(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "\(name) isn’t an image Remanence can read."
        case .alreadyAdded(let name): "\(name) is already on this tape."
        }
    }
}

/// Blank text is stored as nothing, so an emptied field really clears.
private func clean(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

extension Library {
    public static func fetchPost(_ db: Database, tapeID: Int64) throws -> SitePost? {
        guard let tape = try Tape.fetchOne(db, key: tapeID) else { return nil }
        let sources = try Source.filter(Column("tape_id") == tapeID).order(Column("position")).fetchAll(db)
        var tracks: [PostTrack] = []
        var parents: [Int64: Int64] = [:]
        var orders: [Double?] = []
        for source in sources {
            guard let id = source.id, let review = try fetchReview(db, sourceID: id) else { continue }
            for span in review.tracks {
                let stored = try span.trackID.flatMap { try Track.fetchOne(db, key: $0) }
                let details = stored?.summaryDetails
                // A cut that leaves too little, after a marker moved, is ignored.
                let fits = span.end - span.start - span.cutStart - span.cutEnd >= minimumKeptLength
                let cutStart = fits ? span.cutStart : 0, cutEnd = fits ? span.cutEnd : 0
                var track = PostTrack(
                    sourceID: id,
                    startMarkerID: span.markerID,
                    name: span.name,
                    description: stored?.description,
                    start: span.start + cutStart,
                    end: span.end - cutEnd,
                    summaryShort: details?.summaryShort ?? stored?.summaryShort,
                    summaryLong: details?.summaryLong,
                    estimatedEra: details?.estimatedEra,
                    adjustments: span.adjustments
                )
                track.trackID = stored?.id
                track.cutStart = cutStart
                track.cutEnd = cutEnd
                if let stored, let id = stored.id, let parent = stored.appendedToTrackId { parents[id] = parent }
                tracks.append(track)
                orders.append(stored?.sortIndex)
            }
        }
        let images = try TapeImage.filter(Column("tape_id") == tapeID).order(Column("position")).fetchAll(db)
        let ordered = order(tracks, sortIndexes: orders)
        var post = SitePost(tape: tape, tracks: joinAppended(ordered, parents: parents), images: images)
        post.collection = try collection(db, of: tape)
        return post
    }

    /// Puts tracks in their site order. Tracks never moved follow the one before them
    /// on the same recording, so a split stays next to where it came from, and a
    /// recording added later goes at the end. With nothing moved, it's recording order.
    static func order(_ tracks: [PostTrack], sortIndexes: [Double?]) -> [PostTrack] {
        guard sortIndexes.contains(where: { $0 != nil }) else { return tracks }
        let last = (sortIndexes.compactMap(\.self).max() ?? 0) + 1
        var effective: [Double] = []
        var previousOnSource: [Int64: Double] = [:]
        for (index, track) in tracks.enumerated() {
            let value = sortIndexes[index]
                ?? previousOnSource[track.sourceID].map { $0 + 0.001 }
                ?? last + Double(index)
            effective.append(value)
            previousOnSource[track.sourceID] = value
        }
        return tracks.indices.sorted { effective[$0] != effective[$1] ? effective[$0] < effective[$1] : $0 < $1 }.map { tracks[$0] }
    }

    /// Folds appended tracks into the tracks they follow. A track whose parent isn't
    /// on this tape, or that would loop back on itself, stays a track of its own.
    static func joinAppended(_ tracks: [PostTrack], parents: [Int64: Int64]) -> [PostTrack] {
        let present = Set(tracks.compactMap(\.trackID))
        func root(of id: Int64) -> Int64? {
            var seen: Set<Int64> = [id]
            var current = id
            while let parent = parents[current], present.contains(parent) {
                guard seen.insert(parent).inserted else { return nil }
                current = parent
            }
            return current == id ? nil : current
        }
        var children: [Int64: [Int64]] = [:]
        var appended: Set<Int64> = []
        for track in tracks {
            guard let id = track.trackID, let parent = parents[id], present.contains(parent), root(of: id) != nil else { continue }
            children[parent, default: []].append(id)
            appended.insert(id)
        }
        let byID = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in track.trackID.map { ($0, track) } })
        func following(_ id: Int64) -> [PostTrack] {
            (children[id] ?? []).flatMap { child -> [PostTrack] in
                guard let track = byID[child] else { return [] }
                return [track] + following(child)
            }
        }
        return tracks.compactMap { track in
            if let id = track.trackID, appended.contains(id) { return nil }
            var head = track
            if let id = track.trackID { head.continuations = following(id) }
            return head
        }
    }

    public func postUpdates(tapeID: Int64) -> AsyncValueObservation<SitePost?> {
        ValueObservation.tracking { db in try Self.fetchPost(db, tapeID: tapeID) }
            .values(in: database.writer)
    }

    public func savePost(tapeID: Int64, fields: PostFields) async throws {
        try await database.writer.write { db in
            guard var tape = try Tape.fetchOne(db, key: tapeID) else { return }
            if let title = clean(fields.title), title != tape.title {
                tape.title = title
                tape.titleIsProvisional = false
            }
            tape.description = clean(fields.description)
            if let medium = fields.medium { tape.medium = medium.label }
            tape.era = clean(fields.recordedDate)
            tape.whereFound = clean(fields.whereFound)
            tape.dateFound = clean(fields.dateFound)
            try tape.update(db)
        }
    }

    /// Sets a track's name or written description. A track that has no row yet gets one.
    public func saveTrack(sourceID: Int64, startMarkerID: Int64?, name: String? = nil, description: String? = nil) async throws {
        try await database.writer.write { db in
            var track = try Track
                .filter(Column("source_id") == sourceID)
                .filter(startMarkerID == nil ? Column("start_marker_id") == nil : Column("start_marker_id") == startMarkerID)
                .fetchOne(db) ?? Track(sourceId: sourceID, startMarkerId: startMarkerID)
            if let name { track.name = clean(name) }
            if let description { track.description = clean(description) }
            try track.save(db)
        }
    }

    // MARK: Photos

    /// Copies a photo into the library. Formats browsers can't show, like HEIC, become
    /// JPEG. Location is always removed, since phone photos record where they were taken.
    @discardableResult
    public func addImage(tapeID: Int64, from source: URL) async throws -> TapeImage {
        guard let uuid = try await database.writer.read({ db in
            try String.fetchOne(db, sql: "SELECT uuid FROM tape WHERE id = ?", arguments: [tapeID])
        }) else { throw ImageImportError.unreadable(source.lastPathComponent) }

        let folder = paths.images.appending(path: uuid, directoryHint: .isDirectory)
        let prepared = try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try Self.prepareImage(source, in: folder)
        }.value

        do {
            return try await database.writer.write { db in
                if try TapeImage.filter(Column("tape_id") == tapeID && Column("sha256") == prepared.sha256).fetchCount(db) > 0 {
                    throw ImageImportError.alreadyAdded(source.lastPathComponent)
                }
                let next = try Int.fetchOne(db, sql: "SELECT coalesce(max(position), -1) + 1 FROM tape_image WHERE tape_id = ?", arguments: [tapeID]) ?? 0
                var image = TapeImage(
                    tapeId: tapeID,
                    position: next,
                    path: "images/\(uuid)/\(prepared.url.lastPathComponent)",
                    sha256: prepared.sha256,
                    filename: source.deletingPathExtension().lastPathComponent + "." + prepared.url.pathExtension
                )
                try image.insert(db)
                return image
            }
        } catch ImageImportError.alreadyAdded(let name) {
            throw ImageImportError.alreadyAdded(name)
        } catch {
            try? FileManager.default.removeItem(at: prepared.url)
            throw error
        }
    }

    static func prepareImage(_ source: URL, in folder: URL) throws -> (url: URL, sha256: String) {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(image) > 0,
              let type = CGImageSourceGetType(image) as String? else {
            throw ImageImportError.unreadable(source.lastPathComponent)
        }
        let webReady = [UTType.jpeg.identifier, UTType.png.identifier].contains(type)
        let outputType = webReady ? type : UTType.jpeg.identifier
        let extensionName = outputType == UTType.png.identifier ? "png" : "jpg"

        let partial = folder.appending(path: "adding-\(UUID().uuidString).\(extensionName)")
        defer { try? FileManager.default.removeItem(at: partial) }
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, outputType as CFString, 1, nil) else {
            throw ImageImportError.unreadable(source.lastPathComponent)
        }
        let written: Bool
        if webReady {
            // Rewrites only the metadata, so the picture itself isn't recompressed.
            let options = [kCGImageMetadataShouldExcludeGPS: true] as CFDictionary
            written = CGImageDestinationCopyImageSource(destination, image, options, nil)
        } else {
            let options = [
                kCGImageDestinationLossyCompressionQuality: 0.92,
                kCGImagePropertyGPSDictionary: kCFNull as Any,
            ] as CFDictionary
            CGImageDestinationAddImageFromSource(destination, image, 0, options)
            written = CGImageDestinationFinalize(destination)
        }
        guard written else { throw ImageImportError.unreadable(source.lastPathComponent) }

        let hash = try sha256(of: partial)
        let final = folder.appending(path: "\(hash).\(extensionName)")
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: partial, to: final)
        return (final, hash)
    }

    public func removeImage(id: Int64) async throws {
        let path: String? = try await database.writer.write { db in
            guard let image = try TapeImage.fetchOne(db, key: id) else { return nil }
            try image.delete(db)
            try db.execute(sql: """
                UPDATE tape_image SET position = position - 1 WHERE tape_id = ? AND position > ?
                """, arguments: [image.tapeId, image.position])
            return image.path
        }
        if let path { try? FileManager.default.removeItem(at: try url(forLibraryPath: path)) }
    }

    public func setCaption(imageID: Int64, caption: String) async throws {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE tape_image SET caption = ? WHERE id = ?", arguments: [trimmed.isEmpty ? nil : trimmed, imageID])
        }
    }

    /// Moves a photo earlier (-1) or later (+1). The order is the site's photo numbering.
    public func moveImage(id: Int64, by offset: Int) async throws {
        try await database.writer.write { db in
            guard let image = try TapeImage.fetchOne(db, key: id) else { return }
            var images = try TapeImage.filter(Column("tape_id") == image.tapeId).order(Column("position")).fetchAll(db)
            guard let index = images.firstIndex(where: { $0.id == id }) else { return }
            let target = index + offset
            guard images.indices.contains(target) else { return }
            images.swapAt(index, target)
            for (position, var item) in images.enumerated() where item.position != position {
                item.position = position
                try item.update(db)
            }
        }
    }
}
