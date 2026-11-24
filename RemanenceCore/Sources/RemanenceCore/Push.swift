import AVFoundation
import Foundation
import GRDB

public enum PushError: LocalizedError, Equatable {
    case alreadyOnSite
    case notApproved
    case nothingToPush
    case unknownMedium(String?)
    case titleTooLong
    case fileTooLarge(String)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyOnSite: "This tape is already on the site."
        case .notApproved: "Mark this tape as Looks Good before pushing it."
        case .nothingToPush: "This tape has no audio left to push after its trims."
        case .unknownMedium(let medium): "The site has no format matching “\(medium ?? "none")”."
        case .titleTooLong: "The site allows titles up to 256 characters."
        case .fileTooLarge(let name): "\(name) is too large to upload in one piece."
        case .encodingFailed(let name): "Couldn’t make \(name) from the master."
        }
    }
}

/// The site's name for a tape's format, or nil if it doesn't have one.
public func siteMedium(for medium: String?) -> String? {
    SiteMedium(label: medium)?.rawValue
}

/// One track as it will appear on the site.
public struct PushTrack: Identifiable, Equatable, Sendable {
    public let title: String
    public let sourceID: Int64
    public let masterPath: String
    public let start: Double
    public let end: Double
    public let description: String?
    public var adjustments: TrackAdjustments = .none
    /// The master's rate, which adjusted copies keep. Read from the file when unknown.
    public var sampleRate: Int?

    /// Pieces appended to this track, played straight after it.
    public var continuations: [PushPiece] = []

    public var id: String { "\(sourceID)-\(start)" }
    /// How long it plays on the site, at its adjusted speed.
    public var duration: Double {
        adjustments.duration(of: end - start) + continuations.reduce(0) { $0 + $1.adjustments.duration(of: $1.end - $1.start) }
    }

    var pieces: [PushPiece] {
        [PushPiece(sourceID: sourceID, masterPath: masterPath, start: start, end: end, adjustments: adjustments, sampleRate: sampleRate)]
            + continuations
    }
}

/// One stretch of one recording, with how it should sound.
public struct PushPiece: Equatable, Sendable {
    public let sourceID: Int64
    public let masterPath: String
    public let start: Double
    public let end: Double
    public var adjustments: TrackAdjustments = .none
    public var sampleRate: Int?

    var tag: String { "\(sourceID)-\(Int(start * 1000))-\(Int(end * 1000))\(adjustments.fileTag)" }
}

public struct PushPlan: Equatable, Sendable {
    public let tape: Tape
    public let medium: String
    public let machineName: String?
    public let tracks: [PushTrack]
    public let images: [TapeImage]

    public var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
}

public struct PushFile: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case audio, image, transcript
    }

    public let url: URL
    public let sha256: String
    public let bytes: Int64
    public let filename: String
    public let contentType: String
    public let kind: Kind
}

public enum PushProgress: Equatable, Sendable {
    case preparing(track: Int, of: Int)
    case checking
    case uploading(file: Int, of: Int, fraction: Double)
    case creating
}

public struct PushResult: Equatable, Sendable {
    public let catalogNumber: String
    public let uploaded: Int
    public let alreadyThere: Int
}

extension Library {
    /// Works out what a push would send, or why the tape can't be pushed yet.
    public func pushPlan(tapeID: Int64) async throws -> PushPlan {
        try await database.writer.read { db in
            guard let tape = try Tape.fetchOne(db, key: tapeID) else { throw PushError.nothingToPush }
            guard tape.pushedAt == nil else { throw PushError.alreadyOnSite }
            guard tape.approvedAt != nil else { throw PushError.notApproved }
            guard let medium = siteMedium(for: tape.medium) else { throw PushError.unknownMedium(tape.medium) }
            guard tape.title.count <= 256 else { throw PushError.titleTooLong }

            guard let post = try Self.fetchPost(db, tapeID: tapeID), !post.tracks.isEmpty else {
                throw PushError.nothingToPush
            }
            let sources = Dictionary(uniqueKeysWithValues: try Source
                .filter(Column("tape_id") == tapeID).fetchAll(db).compactMap { source in source.id.map { ($0, source) } })
            let tracks = post.tracks.enumerated().map { index, track in
                var push = PushTrack(
                    title: Self.trackTitle(track.name, tape: tape, index: index, count: post.tracks.count),
                    sourceID: track.sourceID,
                    masterPath: sources[track.sourceID]?.masterPath ?? "",
                    start: track.start,
                    end: track.end,
                    // Only what was written by hand. Claude's summary is reference.
                    description: track.description,
                    adjustments: track.adjustments,
                    sampleRate: sources[track.sourceID]?.sampleRate
                )
                push.continuations = track.continuations.map { piece in
                    PushPiece(
                        sourceID: piece.sourceID,
                        masterPath: sources[piece.sourceID]?.masterPath ?? "",
                        start: piece.start,
                        end: piece.end,
                        adjustments: piece.adjustments,
                        sampleRate: sources[piece.sourceID]?.sampleRate
                    )
                }
                return push
            }
            let machine = try tape.machineId.flatMap {
                try String.fetchOne(db, sql: "SELECT name FROM machine WHERE id = ?", arguments: [$0])
            }
            // A tape without its own where and when found goes up with its collection's.
            var sent = tape
            sent.whereFound = post.whereFound
            sent.dateFound = post.dateFound
            return PushPlan(tape: sent, medium: medium, machineName: machine, tracks: tracks, images: post.images)
        }
    }

    private static func trackTitle(_ name: String?, tape: Tape, index: Int, count: Int) -> String {
        if let name, !name.isEmpty { return name }
        if count == 1 { return tape.title }
        return "Track \(index + 1)"
    }

    /// Where a push keeps the files it makes until it finishes.
    func pushFolder(tapeUUID: String) -> URL {
        paths.processed.appending(path: tapeUUID, directoryHint: .isDirectory)
            .appending(path: "push", directoryHint: .isDirectory)
    }

    fileprivate func markPushed(tapeID: Int64, catalogNumber: String, now: Date) async throws {
        // GRDB refuses writes from a cancelled task, and the entry already exists by now.
        try await Task.detached { [database] in
            try await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE tape SET catalog_number = ?, pushed_at = ? WHERE id = ?",
                    arguments: [catalogNumber, now, tapeID]
                )
            }
        }.value
    }

    fileprivate func transcriptJSON(tapeID: Int64) async throws -> Data? {
        struct Line: Encodable {
            let side: String?
            let start: Double
            let end: Double
            let text: String
        }
        let lines: [Line] = try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.side, g.start_time, g.end_time, g.text FROM segment g
                JOIN source s ON s.id = g.source_id
                WHERE s.tape_id = ?
                ORDER BY s.position, g.start_time
                """, arguments: [tapeID]).map {
                Line(side: $0["side"], start: $0["start_time"], end: $0["end_time"], text: $0["text"])
            }
        }
        guard !lines.isEmpty else { return nil }
        let encoder = JSONEncoder()
        // The same transcript has to produce the same bytes, and so the same hash.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(lines)
    }
}

/// Sends a tape to the site.
///
/// Each step can be repeated safely, so pressing Push again after any failure picks up
/// where it stopped: finished encodes are reused, uploaded files are skipped, and the
/// site returns the existing entry if it was already created.
public struct Pusher: Sendable {
    /// Storage accepts up to 5 GB in a single upload.
    static let largestUpload: Int64 = 4_900_000_000

    let library: Library
    let site: any SiteAPI
    var ffmpeg = KnownTools.ffmpeg
    var retryDelays: [Duration] = [.seconds(2), .seconds(10)]
    var now: @Sendable () -> Date = { Date() }

    public init(library: Library, site: any SiteAPI) {
        self.library = library
        self.site = site
    }

    @discardableResult
    public func push(tapeID: Int64, progress: @escaping @Sendable (PushProgress) -> Void = { _ in }) async throws -> PushResult {
        let plan = try await library.pushPlan(tapeID: tapeID)
        let folder = library.pushFolder(tapeUUID: plan.tape.uuid)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var tracks: [SiteEntry.Track] = []
        var files: [PushFile] = []
        for (index, track) in plan.tracks.enumerated() {
            progress(.preparing(track: index + 1, of: plan.tracks.count))
            let (audio, download) = try await prepare(track, number: index + 1, in: folder)
            files += [download, audio]
            tracks.append(SiteEntry.Track(
                title: track.title,
                audioSha256: audio.sha256,
                audioFilename: audio.filename,
                downloadSha256: download.sha256,
                downloadFilename: download.filename,
                duration: track.duration,
                description: track.description
            ))
        }

        var images: [SiteEntry.Image] = []
        for image in plan.images {
            let url = try library.url(forLibraryPath: image.path)
            let type = url.pathExtension == "png" ? "image/png" : "image/jpeg"
            let file = try describe(url, filename: image.filename, contentType: type, kind: .image)
            files.append(file)
            images.append(SiteEntry.Image(sha256: file.sha256, filename: image.filename, caption: image.caption))
        }

        var transcriptHash: String?
        if let transcript = try await library.transcriptJSON(tapeID: tapeID) {
            let url = folder.appending(path: "transcript.json")
            try transcript.write(to: url, options: .atomic)
            let file = try describe(url, filename: "transcript.json", contentType: "application/json", kind: .transcript)
            files.append(file)
            transcriptHash = file.sha256
        }

        // Identical audio only needs sending once.
        var seen = Set<String>()
        files = files.filter { seen.insert($0.sha256).inserted }

        progress(.checking)
        let existing = try await site.existingFiles(files.map(\.sha256))
        let missing = files.filter { !existing.contains($0.sha256) }
        if let tooLarge = missing.first(where: { $0.bytes > Self.largestUpload }) {
            throw PushError.fileTooLarge(tooLarge.filename)
        }

        for (index, file) in missing.enumerated() {
            let report: @Sendable (Double) -> Void = { fraction in
                progress(.uploading(file: index + 1, of: missing.count, fraction: fraction))
            }
            report(0)
            try await send(file, progress: report)
        }

        progress(.creating)
        var entry = SiteEntry(
            tapeUuid: plan.tape.uuid,
            title: plan.tape.title,
            medium: plan.medium,
            description: plan.tape.description,
            estimatedRecordingDate: plan.tape.era,
            whereFound: plan.tape.whereFound,
            dateFound: plan.tape.dateFound,
            tracks: tracks,
            images: images,
            transcriptSha256: transcriptHash,
            metadata: metadata(for: plan)
        )
        entry.catalogNumber = plan.tape.catalogNumber
        let state = try await site.createEntry(entry)
        try await library.markPushed(tapeID: tapeID, catalogNumber: state.catalogNumber, now: now())
        // The site's answer is what later updates are worked out against. The tracks are
        // known to it by their streaming copies.
        let post = try await library.database.writer.read { try Library.fetchPost($0, tapeID: tapeID) }
        if let post {
            let sentHashes = Dictionary(uniqueKeysWithValues: zip(post.tracks.map { TrackKey($0.sourceID, $0.startMarkerID) }, tracks.map(\.audioSha256)))
            let previous = SiteSnapshot(
                published: state.published,
                fields: .init(title: state.title, medium: state.medium),
                tracks: post.tracks.compactMap { track in
                    sentHashes[TrackKey(track.sourceID, track.startMarkerID)].map {
                        SiteSnapshot.Track(sourceID: track.sourceID, startMarkerID: track.startMarkerID, start: track.start, end: track.end, sha256: $0, title: "", description: nil)
                    }
                },
                images: []
            )
            try await recordSiteState(state, tapeID: tapeID, post: post, previous: previous)
        }
        try? FileManager.default.removeItem(at: folder)

        return PushResult(catalogNumber: state.catalogNumber, uploaded: missing.count, alreadyThere: files.count - missing.count)
    }

    private func metadata(for plan: PushPlan) -> [String: String] {
        var metadata: [String: String] = [:]
        metadata["machine"] = plan.machineName
        metadata["speed"] = plan.tape.speed
        return metadata
    }

    /// A fresh upload URL is requested for each attempt, because they expire quickly.
    func send(_ file: PushFile, progress: @escaping @Sendable (Double) -> Void) async throws {
        var attempt = 0
        while true {
            do {
                let upload = try await site.requestUpload(file)
                try await site.upload(file, to: upload.url, progress: progress)
                try await site.recordFile(file, key: upload.key)
                return
            } catch {
                guard Self.isTemporary(error), attempt < retryDelays.count else { throw error }
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    static func isTemporary(_ error: Error) -> Bool {
        if let error = error as? SiteError { return error.isTemporary }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed]
            .contains(error.code)
    }

    private func prepare(_ track: PushTrack, number: Int, in folder: URL) async throws -> (audio: PushFile, download: PushFile) {
        if !track.continuations.isEmpty { return try await prepareJoined(track, number: number, in: folder) }
        let master = try library.url(forLibraryPath: track.masterPath)
        let span = "\(track.sourceID)-\(Int(track.start * 1000))-\(Int(track.end * 1000))\(track.adjustments.fileTag)"
        let name = Self.filename(for: track.title, number: number)

        let flac = folder.appending(path: "\(span).flac")
        let mp3 = folder.appending(path: "\(span).mp3")
        let finished = [flac, mp3].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }

        // ffmpeg can only reverse by holding a whole track in memory, so a reversed
        // track is first written backwards to a file of its own, a second at a time.
        var input = Input(url: master, start: track.start, end: track.end)
        let reversed = folder.appending(path: "\(span).reversed.caf")
        if track.adjustments.reversed, !finished {
            let partial = folder.appending(path: "\(span).reversed.partial.caf")
            try await Task.detached(priority: .userInitiated) {
                try writeReversed(master, from: track.start, to: track.end, into: partial)
            }.value
            try? FileManager.default.removeItem(at: reversed)
            try FileManager.default.moveItem(at: partial, to: reversed)
            input = Input(url: reversed, start: nil, end: nil)
        }
        defer { try? FileManager.default.removeItem(at: reversed) }

        let rate = try track.sampleRate ?? Int(AVAudioFile(forReading: master).fileFormat.sampleRate)
        let filters = track.adjustments.filters(sampleRate: rate).map { ["-af", $0] } ?? []
        // Adjusted or not, the download keeps the master's rate and depth.
        try await encode(input, track, to: flac, codec: filters + ["-c:a", "flac", "-compression_level", "8"])
        // These match the settings the site's admin uses for streaming copies.
        try await encode(input, track, to: mp3, codec: filters + ["-c:a", "libmp3lame", "-b:a", "192k", "-ar", "44100", "-ac", "2"])

        return (
            try describe(mp3, filename: "\(name).mp3", contentType: "audio/mpeg", kind: .audio),
            try describe(flac, filename: "\(name).flac", contentType: "audio/flac", kind: .audio)
        )
    }

    /// A track made of pieces: each is made on its own, as it should sound, at the
    /// first piece's rate, then they're joined. The masters are only read.
    private func prepareJoined(_ track: PushTrack, number: Int, in folder: URL) async throws -> (audio: PushFile, download: PushFile) {
        let pieces = track.pieces
        let tags = pieces.map(\.tag).joined(separator: "+")
        let span = "joined-" + sha256(of: Data(tags.utf8)).prefix(16)
        let name = Self.filename(for: track.title, number: number)
        let flac = folder.appending(path: "\(span).flac")
        let mp3 = folder.appending(path: "\(span).mp3")

        var made: [URL] = []
        defer { for url in made { try? FileManager.default.removeItem(at: url) } }
        if ![flac, mp3].allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            let masters = try pieces.map { try library.url(forLibraryPath: $0.masterPath) }
            let rate = try pieces[0].sampleRate ?? Int(AVAudioFile(forReading: masters[0]).fileFormat.sampleRate)
            let channels = try masters.map { Int(try AVAudioFile(forReading: $0).fileFormat.channelCount) }.max() ?? 1

            for (index, piece) in pieces.enumerated() {
                let master = masters[index]
                var input = Input(url: master, start: piece.start, end: piece.end)
                if piece.adjustments.reversed {
                    let reversed = folder.appending(path: "\(span)-\(index).reversed.caf")
                    let partial = folder.appending(path: "\(span)-\(index).reversed.partial.caf")
                    try await Task.detached(priority: .userInitiated) {
                        try writeReversed(master, from: piece.start, to: piece.end, into: partial)
                    }.value
                    try? FileManager.default.removeItem(at: reversed)
                    try FileManager.default.moveItem(at: partial, to: reversed)
                    made.append(reversed)
                    input = Input(url: reversed, start: nil, end: nil)
                }
                let pieceRate = try piece.sampleRate ?? Int(AVAudioFile(forReading: master).fileFormat.sampleRate)
                let filters = piece.adjustments.filters(sampleRate: pieceRate).map { ["-af", $0] } ?? []
                let output = folder.appending(path: "\(span)-\(index).wav")
                try? FileManager.default.removeItem(at: output)
                made.append(output)
                try await encode(input, track, to: output, codec: filters + [
                    "-c:a", "pcm_s24le", "-ar", "\(rate)", "-ac", "\(channels)",
                ])
            }
            let parts = (0..<pieces.count).map { folder.appending(path: "\(span)-\($0).wav") }
            try await encodeJoined(parts, track, to: flac, codec: ["-c:a", "flac", "-compression_level", "8"])
            try await encodeJoined(parts, track, to: mp3, codec: ["-c:a", "libmp3lame", "-b:a", "192k", "-ar", "44100", "-ac", "2"])
        }
        return (
            try describe(mp3, filename: "\(name).mp3", contentType: "audio/mpeg", kind: .audio),
            try describe(flac, filename: "\(name).flac", contentType: "audio/flac", kind: .audio)
        )
    }

    /// Joins prepared pieces end to end into one file.
    private func encodeJoined(_ parts: [URL], _ track: PushTrack, to output: URL, codec: [String]) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { return }
        let extensionName = output.pathExtension
        let partial = output.deletingPathExtension().appendingPathExtension("partial.\(extensionName)")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        let inputs = parts.flatMap { ["-i", $0.path] }
        let labels = parts.indices.map { "[\($0):a:0]" }.joined()
        let arguments = ["-v", "error", "-y"] + inputs + [
            "-filter_complex", "\(labels)concat=n=\(parts.count):v=0:a=1[joined]",
            "-map", "[joined]", "-map_metadata", "-1",
        ] + codec + ["-bitexact", "-fflags", "+bitexact", partial.path]

        let (status, _) = try await runToolCapturingOutput(ffmpeg, arguments: arguments, timeout: .seconds(4 * 3600))
        guard status == 0, FileManager.default.fileExists(atPath: partial.path) else {
            throw PushError.encodingFailed(track.title)
        }
        try FileManager.default.moveItem(at: partial, to: output)
    }

    /// Audio to encode from: a stretch of the master, or a whole prepared file.
    private struct Input {
        let url: URL
        let start: Double?
        let end: Double?
    }

    /// Cuts one track from the master, which is only ever read. The result is bit-exact,
    /// so the same audio always makes the same file and the same hash. A finished file
    /// from an interrupted push is reused.
    private func encode(_ input: Input, _ track: PushTrack, to output: URL, codec: [String]) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { return }
        let extensionName = output.pathExtension
        let partial = output.deletingPathExtension().appendingPathExtension("partial.\(extensionName)")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        var range: [String] = []
        if let start = input.start { range += ["-ss", String(format: "%.6f", start)] }
        if let end = input.end { range += ["-to", String(format: "%.6f", end)] }
        let arguments = ["-v", "error", "-y"] + range + [
            "-i", input.url.path,
            "-map", "0:a:0", "-map_metadata", "-1",
        ] + codec + ["-bitexact", "-fflags", "+bitexact", partial.path]

        let (status, _) = try await runToolCapturingOutput(ffmpeg, arguments: arguments, timeout: .seconds(4 * 3600))
        guard status == 0, FileManager.default.fileExists(atPath: partial.path) else {
            throw PushError.encodingFailed(track.title)
        }
        try FileManager.default.moveItem(at: partial, to: output)
    }

    func describe(_ url: URL, filename: String, contentType: String, kind: PushFile.Kind) throws -> PushFile {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return PushFile(
            url: url,
            sha256: try sha256(of: url),
            bytes: Int64(bytes),
            filename: filename,
            contentType: contentType,
            kind: kind
        )
    }

    static func filename(for title: String, number: Int) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(80))
        return String(format: "%02d ", number) + (short.isEmpty ? "Track" : short)
    }
}
