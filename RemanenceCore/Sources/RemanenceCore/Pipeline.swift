import Foundation
import GRDB

public enum PipelineError: LocalizedError, Equatable {
    case toolFailed(String, String)
    case noPreparedAudio
    case wouldOverwriteEdits
    case missingRecord
    case unreadableTranscript

    public var errorDescription: String? {
        switch self {
        case .toolFailed(let tool, let detail): "\(tool) failed. \(detail)"
        case .noPreparedAudio: "The prepared audio is missing."
        case .wouldOverwriteEdits: "This transcript has your edits, so it wasn’t replaced."
        case .missingRecord: "This recording is no longer in your library."
        case .unreadableTranscript: "Whisper’s transcript couldn’t be read."
        }
    }
}

/// The real work behind each job type.
public struct Pipeline: Sendable {
    public let database: AppDatabase
    public let paths: LibraryPaths
    public var ffmpeg = KnownTools.ffmpeg
    public var whisper = KnownTools.whisper
    public var claude = KnownTools.claude

    public init(database: AppDatabase, paths: LibraryPaths) {
        self.database = database
        self.paths = paths
    }

    public var tools: [URL] { [ffmpeg, whisper, claude] }

    public func hasModel(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(name).path)
    }

    func modelURL(_ name: String) -> URL {
        paths.models.appending(path: "ggml-\(name).en.bin")
    }

    public func run(_ job: Job, context: JobContext) async throws {
        switch job.type {
        case .prep: try await prep(job, context: context)
        case .transcribe: try await transcribe(job, context: context)
        case .summarize: try await summarize(job, context: context)
        }
    }

    /// Prepares audio for Whisper, leaving the master untouched: mono 16 kHz first
    /// so later filters have less to do, then hum notches, rumble and hiss removal,
    /// compression and loudness normalization.
    static let prepFilters = [
        "aformat=sample_rates=16000:channel_layouts=mono",
        "bandreject=f=60:width_type=q:w=5",
        "bandreject=f=120:width_type=q:w=5",
        "bandreject=f=180:width_type=q:w=5",
        "bandreject=f=240:width_type=q:w=5",
        "highpass=f=80",
        "afftdn=nf=-25",
        "acompressor=threshold=-20dB:ratio=3:attack=5:release=50:makeup=2",
        "loudnorm=I=-16:TP=-1.5:LRA=11",
    ].joined(separator: ",")

    private func prep(_ job: Job, context: JobContext) async throws {
        let source = try await source(for: job)
        let master = try libraryURL(source.masterPath)

        let folder = URL(filePath: source.masterPath).deletingLastPathComponent().lastPathComponent
        let stem = master.deletingPathExtension().lastPathComponent
        let relative = "processed/\(folder)/\(stem).prep.wav"
        let output = try libraryURL(relative)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        // The name must still end in .wav, because ffmpeg picks its format from it.
        let partial = output.deletingLastPathComponent().appending(path: "\(stem).partial.wav")
        try await runChecked(
            ffmpeg,
            name: "FFmpeg",
            arguments: [
                "-nostdin", "-y", "-i", master.path, "-map", "0:a:0",
                "-af", Self.prepFilters, "-threads", "0",
                "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", partial.path,
            ],
            timeout: .seconds(max(3600, source.duration)),
            context: context
        )

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)

        let sourceID = source.id
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE source SET prep_path = ? WHERE id = ?", arguments: [relative, sourceID])
        }
    }

    private func transcribe(_ job: Job, context: JobContext) async throws {
        let source = try await source(for: job)
        guard let prepPath = source.prepPath,
              case let prepared = try libraryURL(prepPath),
              FileManager.default.fileExists(atPath: prepared.path) else {
            throw PipelineError.noPreparedAudio
        }
        guard let sourceID = source.id else { throw PipelineError.missingRecord }

        // Don't start a long run whose result couldn't be saved.
        if !job.candidate {
            let hasEdits = try await database.writer.read { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM segment WHERE source_id = ? AND edited = 1)", arguments: [sourceID]) ?? false
            }
            if hasEdits { throw PipelineError.wouldOverwriteEdits }
        }

        let model = job.model ?? "base"
        let vad = modelURL("silero-v5.1.2").deletingLastPathComponent().appending(path: "ggml-silero-v5.1.2.bin")

        let work = try makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let outputBase = work.appending(path: "out")
        let log = work.appending(path: "stderr.txt")

        // Progress is written to stderr, so it's read back from the file.
        let watcher = Task {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                if let fraction = Self.whisperProgress(inLogAt: log) { context.reportProgress(fraction) }
            }
        }
        defer { watcher.cancel() }

        // --vad needs its model, or whisper-cli aborts. Without VAD it invents
        // repeated phrases over music and silence.
        try await runChecked(
            whisper,
            name: "Whisper",
            arguments: [
                "--model", modelURL(model).path,
                "--file", prepared.path,
                "--output-json", "--output-file", outputBase.path,
                "--print-progress", "--language", "en",
                "--vad", "--vad-model", vad.path,
            ],
            timeout: .seconds(max(3600, source.duration)),
            standardError: log,
            context: context
        )

        let data = try Data(contentsOf: work.appending(path: "out.json"))
        let segments = try Self.parseWhisper(data)

        if job.candidate {
            let json = String(decoding: try JSONEncoder().encode(segments), as: UTF8.self)
            try await database.writer.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO transcript_candidate (source_id, model, segments) VALUES (?, ?, ?)",
                    arguments: [sourceID, model, json]
                )
            }
            return
        }

        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM segment WHERE source_id = ?", arguments: [sourceID])
            for segment in segments {
                try db.execute(
                    sql: "INSERT INTO segment (source_id, start_time, end_time, text) VALUES (?, ?, ?, ?)",
                    arguments: [sourceID, segment.start, segment.end, segment.text]
                )
            }
            try db.execute(sql: "UPDATE source SET transcript_model = ? WHERE id = ?", arguments: [model, sourceID])
        }
    }

    private func summarize(_ job: Job, context: JobContext) async throws {
        guard let trackID = job.trackId else { throw PipelineError.missingRecord }
        let (track, source, tape, transcript) = try await summaryInputs(trackID: trackID)

        let work = try makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let promptFile = work.appending(path: "prompt.txt")
        try SummaryPrompt.build(
            title: track.name ?? tape.title,
            fileName: URL(filePath: source.masterPath).lastPathComponent,
            duration: source.duration,
            context: tape.context,
            transcript: transcript
        ).write(to: promptFile, atomically: true, encoding: .utf8)

        // Hooks, settings and tools are all off. This only needs to read text, and
        // transcript content can't trigger anything with no tools available.
        let output = work.appending(path: "stdout.json")
        try await runChecked(
            claude,
            name: "Claude Code",
            arguments: ["-p", "--output-format", "json", "--setting-sources", "", "--tools", "", "--no-session-persistence"],
            timeout: .seconds(300),
            standardInput: promptFile,
            standardOutput: output,
            acceptAnyStatus: true,
            context: context
        )

        let summary = try SummaryParser.parse(
            try SummaryParser.resultText(fromEnvelope: try Data(contentsOf: output))
        )

        try await database.writer.write { db in
            let previousLong = try Track.fetchOne(db, key: trackID)?.summaryDetails?.summaryLong
            try db.execute(
                sql: "UPDATE track SET recording_type = ?, summary_short = ?, summary = ? WHERE id = ?",
                arguments: [summary.recordingType, summary.summaryShort, summary.json, trackID]
            )
            // Fills gaps only. Anything you or the site already set is left alone,
            // though a description that came from an earlier summary can be updated.
            guard var current = try Tape.fetchOne(db, key: tape.id) else { return }
            if current.titleIsProvisional, !summary.suggestedTitle.isEmpty {
                current.title = summary.suggestedTitle
                current.titleIsProvisional = false
            }
            let cameFromSummary = previousLong != nil && current.description == previousLong
            if current.description == nil || cameFromSummary, !summary.summaryLong.isEmpty {
                current.description = summary.summaryLong
            }
            if current.era == nil, !summary.estimatedEra.isEmpty { current.era = summary.estimatedEra }
            try current.update(db)
        }
    }

    // MARK: Helpers

    private func source(for job: Job) async throws -> Source {
        guard let id = job.sourceId,
              let source = try await database.writer.read({ db in try Source.fetchOne(db, key: id) }) else {
            throw PipelineError.missingRecord
        }
        return source
    }

    private func summaryInputs(trackID: Int64) async throws -> (Track, Source, Tape, String) {
        try await database.writer.read { db in
            guard let track = try Track.fetchOne(db, key: trackID),
                  let source = try Source.fetchOne(db, key: track.sourceId),
                  let tape = try Tape.fetchOne(db, key: source.tapeId) else {
                throw PipelineError.missingRecord
            }
            let times = try Double.fetchAll(db, sql: "SELECT time FROM marker WHERE source_id = ?", arguments: [track.sourceId])
            let startMarker = try track.startMarkerId.flatMap {
                try Double.fetchOne(db, sql: "SELECT time FROM marker WHERE id = ?", arguments: [$0])
            }
            let spans = trackSpans(duration: source.duration, trimStart: source.trimStart, trimEnd: source.trimEnd, markers: times)
            let span = spans.first { $0.startMarker == startMarker }
            let text = try String.fetchAll(
                db,
                sql: "SELECT text FROM segment WHERE source_id = ? AND start_time >= ? AND start_time < ? ORDER BY start_time",
                arguments: [track.sourceId, span?.start ?? 0, span?.end ?? source.duration]
            ).joined(separator: " ")
            return (track, source, tape, text)
        }
    }

    private func libraryURL(_ path: String) throws -> URL {
        try Library(database: database, paths: paths).url(forLibraryPath: path)
    }

    private func makeWorkFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "remanence-job-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func runChecked(
        _ tool: URL,
        name: String,
        arguments: [String],
        timeout: TimeInterval,
        standardInput: URL? = nil,
        standardOutput: URL? = nil,
        standardError: URL? = nil,
        acceptAnyStatus: Bool = false,
        context: JobContext
    ) async throws {
        try await runChecked(
            tool, name: name, arguments: arguments, timeout: .seconds(timeout),
            standardInput: standardInput, standardOutput: standardOutput, standardError: standardError,
            acceptAnyStatus: acceptAnyStatus, context: context
        )
    }

    private func runChecked(
        _ tool: URL,
        name: String,
        arguments: [String],
        timeout: Duration,
        standardInput: URL? = nil,
        standardOutput: URL? = nil,
        standardError: URL? = nil,
        acceptAnyStatus: Bool = false,
        context: JobContext
    ) async throws {
        let work = try makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let stdout = standardOutput ?? work.appending(path: "stdout.txt")
        let stderr = standardError ?? work.appending(path: "stderr.txt")

        let status = try await runSubprocess(
            tool,
            arguments: arguments,
            standardInput: standardInput,
            standardOutput: stdout,
            standardError: stderr,
            timeout: timeout,
            onSpawn: context.reportPID
        )
        guard status == 0 || acceptAnyStatus else {
            throw PipelineError.toolFailed(name, Self.lastLines(of: stderr))
        }
    }

    static func lastLines(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data.suffix(600), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .suffix(3)
            .joined(separator: " ")
    }

    static func whisperProgress(inLogAt url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data.suffix(4096), as: UTF8.self)
        guard let range = text.range(of: "progress =", options: .backwards) else { return nil }
        // Whisper pads the number to a fixed width, as in "progress =   5%".
        let digits = text[range.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        return Double(digits).map { min($0 / 100, 1) }
    }

    static func parseWhisper(_ data: Data) throws -> [TranscriptLine] {
        struct Output: Decodable {
            struct Item: Decodable {
                struct Offsets: Decodable {
                    let from: Int
                    let to: Int
                }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Item]
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: data) else {
            throw PipelineError.unreadableTranscript
        }
        return output.transcription.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptLine(start: Double(item.offsets.from) / 1000, end: Double(item.offsets.to) / 1000, text: text)
        }
    }
}
