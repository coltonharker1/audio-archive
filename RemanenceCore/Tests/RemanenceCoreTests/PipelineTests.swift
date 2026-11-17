import Foundation
import GRDB
import Testing
@testable import RemanenceCore

@Suite struct SummaryTests {
    @Test func promptIncludesWhatTheModelNeeds() {
        let prompt = SummaryPrompt.build(
            title: "Morning Service", fileName: "tape.wav", duration: 600,
            context: "Found at an estate sale.", transcript: "Let us pray."
        )
        #expect(prompt.contains("Title: \"Morning Service\". Source filename: \"tape.wav\"."))
        #expect(prompt.contains("- Duration: 10.0 minutes"))
        #expect(prompt.contains("Found at an estate sale."))
        #expect(prompt.contains("  - musical_performance — singing"))
        #expect(prompt.contains("bible_references"))
        #expect(prompt.hasSuffix("## Transcript\n\nLet us pray."))
    }

    @Test func contextSectionIsLeftOutWhenEmpty() {
        let prompt = SummaryPrompt.build(title: "T", fileName: "f", duration: 60, context: nil, transcript: "x")
        #expect(!prompt.contains("User-Provided Context"))
    }

    @Test func speechDensityFlagsNonSpeechAudio() {
        #expect(SummaryPrompt.speechDensity(words: 7000, duration: 3600).contains("normal speech"))
        #expect(SummaryPrompt.speechDensity(words: 3000, duration: 3600).contains("slower than typical"))
        #expect(SummaryPrompt.speechDensity(words: 1000, duration: 3600).contains("sparse speech"))
        #expect(SummaryPrompt.speechDensity(words: 2, duration: 3600).contains("almost certainly primarily non-speech"))
        #expect(SummaryPrompt.speechDensity(words: 10, duration: 0).isEmpty)
    }

    /// Claude Code exits successfully with this when it isn't signed in.
    @Test func aReportedErrorIsAFailureEvenWithSuccessfulExit() throws {
        let data = Data(#"{"is_error":true,"subtype":"success","result":"Not logged in · Please run /login"}"#.utf8)
        #expect(throws: SummaryError.claudeReported("Not logged in · Please run /login")) {
            _ = try SummaryParser.resultText(fromEnvelope: data)
        }
    }

    @Test func readsTheEnvelope() throws {
        let data = Data(#"{"is_error":false,"result":"{\"mood\":\"calm\"}","session_id":"x"}"#.utf8)
        #expect(try SummaryParser.resultText(fromEnvelope: data) == #"{"mood":"calm"}"#)
    }

    @Test func aMalformedEnvelopeIsRejected() {
        #expect(throws: SummaryError.self) { _ = try SummaryParser.resultText(fromEnvelope: Data("nope".utf8)) }
    }

    @Test func fencesAreStripped() throws {
        let summary = try SummaryParser.parse("```json\n{\"recording_type\":\"sermon\",\"summary_short\":\"Short\"}\n```")
        #expect(summary.recordingType == "sermon")
        #expect(summary.summaryShort == "Short")
    }

    @Test func invalidJSONIsRejected() {
        #expect(throws: SummaryError.self) { _ = try SummaryParser.parse("Here is your summary!") }
    }

    private func normalized(_ json: String) throws -> [String: Any] {
        let summary = try SummaryParser.parse(json)
        return try JSONSerialization.jsonObject(with: Data(summary.json.utf8)) as! [String: Any]
    }

    @Test func missingListsBecomeEmptyAndTypeDefaults() throws {
        let object = try normalized("{}")
        #expect((object["people"] as? [Any])?.isEmpty == true)
        #expect((object["tags"] as? [Any])?.isEmpty == true)
        #expect(object["recording_type"] as? String == "other")
        #expect((object["type_specific"] as? [String: Any])?.isEmpty == true)
    }

    @Test func placeholdersAreRemoved() throws {
        let object = try normalized(#"{"people":["Carl","Unknown","N/A"],"mood":"none","estimated_era":"1960s"}"#)
        #expect(object["people"] as? [String] == ["Carl"])
        #expect(object["mood"] as? String == "")
        #expect(object["estimated_era"] as? String == "1960s")
    }

    @Test func tagsAreTidied() throws {
        #expect(try normalized(#"{"tags":[" Hymn Singing ","GRACE"]}"#)["tags"] as? [String] == ["hymn-singing", "grace"])
    }

    @Test func typeSpecificFieldsNestedUnderTheTypeAreFlattened() throws {
        let object = try normalized(#"{"recording_type":"sermon","type_specific":{"sermon":{"scripture_focus":"Revelation 13"}}}"#)
        #expect((object["type_specific"] as? [String: Any])?["scripture_focus"] as? String == "Revelation 13")
    }

    @Test func typeSpecificPlaceholdersAreRemovedAtEveryLevel() throws {
        let object = try normalized(#"{"type_specific":{"host":"Unknown","guests":["N/A","Ann"],"nested":{"x":"none"},"count":3,"flag":false,"items":[{"title":"unknown"},{"title":"Hymn"}]}}"#)
        let specific = try #require(object["type_specific"] as? [String: Any])
        #expect(specific["host"] == nil)
        #expect(specific["guests"] as? [String] == ["Ann"])
        #expect(specific["nested"] == nil)
        #expect(specific["count"] as? Int == 3)
        #expect(specific["flag"] as? Bool == false)
        #expect((specific["items"] as? [[String: String]])?.count == 1)
    }
}

@Suite struct WhisperOutputTests {
    @Test func readsSegments() throws {
        let data = Data(#"{"transcription":[{"offsets":{"from":6150,"to":11210},"text":" Hello there. "},{"offsets":{"from":11210,"to":12000},"text":"   "}]}"#.utf8)
        #expect(try Pipeline.parseWhisper(data) == [TranscriptLine(start: 6.15, end: 11.21, text: "Hello there.")])
    }

    @Test func badOutputIsRejected() {
        #expect(throws: PipelineError.unreadableTranscript) { _ = try Pipeline.parseWhisper(Data("{}".utf8)) }
    }

    @Test func readsTheLatestProgress() throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "progress-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: log) }
        #expect(Pipeline.whisperProgress(inLogAt: log) == nil)

        try "noise with no progress\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(Pipeline.whisperProgress(inLogAt: log) == nil)

        try "noise\nwhisper_print_progress_callback: progress =   5%\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(Pipeline.whisperProgress(inLogAt: log) == 0.05)

        try "whisper_print_progress_callback: progress =   5%\nwhisper_print_progress_callback: progress =  42%\nmore".write(to: log, atomically: true, encoding: .utf8)
        #expect(Pipeline.whisperProgress(inLogAt: log) == 0.42)

        try "whisper_print_progress_callback: progress = 100%\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(Pipeline.whisperProgress(inLogAt: log) == 1)
    }
}

/// Runs the pipeline with stand-in tools that behave like the real ones.
@Suite struct PipelineJobTests {
    let fixture: BackupFixture
    let tools: URL

    init() throws {
        fixture = try BackupFixture()
        tools = fixture.library.library.deletingLastPathComponent().appending(path: "tools", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    }

    private func tool(_ name: String, _ body: String) throws -> URL {
        let url = tools.appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private let noContext = JobContext(reportProgress: { _ in }, reportPID: { _ in })

    private func pipeline(_ database: AppDatabase) throws -> Pipeline {
        var pipeline = Pipeline(database: database, paths: fixture.library)
        // Writes a fake prepared file to the last argument, like ffmpeg.
        pipeline.ffmpeg = try tool("ffmpeg", #"for last; do :; done; echo prepared > "$last""#)
        // Writes a transcript to the --output-file path, like whisper-cli.
        pipeline.whisper = try tool("whisper", #"""
            while [ $# -gt 0 ]; do
              if [ "$1" = "--output-file" ]; then base="$2"; fi
              shift
            done
            echo 'whisper_print_progress_callback: progress = 50%' >&2
            cat > "$base.json" <<'JSON'
            {"transcription":[{"offsets":{"from":0,"to":2000},"text":" Hello there. "},{"offsets":{"from":2000,"to":4000},"text":"Second line."}]}
            JSON
            """#)
        // Echoes a canned summary, like claude -p.
        pipeline.claude = try tool("claude", #"""
            cat > /dev/null
            cat <<'JSON'
            {"is_error":false,"result":"{\"recording_type\":\"voicemail\",\"summary_short\":\"Short.\",\"summary_long\":\"Long.\",\"suggested_title\":\"A Better Title\",\"estimated_era\":\"1990s\",\"tags\":[\"Call Back\"]}"}
            JSON
            """#)
        return pipeline
    }

    /// Adds a tape through the drop path with the full pipeline queued.
    private func dropTape(_ database: AppDatabase) async throws -> ShelfTape {
        let file = tools.appending(path: "My_Voicemail.wav")
        try BackupFixture.wav(seconds: 1, seed: "drop").write(to: file)
        let importer = DropImporter(database: database, paths: fixture.library) { _ in true }
        #expect(await importer.add([file]).added == ["My Voicemail"])
        return try #require(try await database.writer.read { db in try Library.fetchShelf(db).first })
    }

    private func runAll(_ pipeline: Pipeline, _ database: AppDatabase) async throws {
        while let job = try await database.writer.write({ db in try JobStore.claimNext(db) }) {
            try await pipeline.run(job, context: noContext)
            try await database.writer.write { db in try JobStore.complete(db, jobID: job.id!) }
        }
    }

    @Test func aDroppedFileGoesAllTheWayThrough() async throws {
        let (database, _, _) = try fixture.open()
        let pipeline = try pipeline(database)
        let added = try await dropTape(database)
        #expect(added.tape.title == "My Voicemail")
        #expect(added.tape.titleIsProvisional)
        #expect(added.status == .waiting)

        try await runAll(pipeline, database)

        let (tape, source, track, segments) = try await database.writer.read { db in
            (
                try Tape.fetchOne(db)!,
                try Source.fetchOne(db)!,
                try Track.fetchOne(db)!,
                try String.fetchAll(db, sql: "SELECT text FROM segment ORDER BY start_time")
            )
        }
        #expect(tape.title == "A Better Title")
        #expect(!tape.titleIsProvisional)
        // The description and date are written by hand. The summary is only reference.
        #expect(tape.description == nil)
        #expect(tape.era == nil)
        #expect(track.summaryDetails?.summaryLong == "Long.")
        #expect(track.description == nil)
        #expect(source.prepPath?.hasPrefix("processed/") == true)
        #expect(source.transcriptModel == "base")
        #expect(track.recordingType == "voicemail")
        #expect(track.summaryShort == "Short.")
        #expect(track.summary?.contains("call-back") == true)
        #expect(segments == ["Hello there.", "Second line."])

        let prepared = fixture.library.library.appending(path: source.prepPath!)
        #expect(FileManager.default.fileExists(atPath: prepared.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: prepared.deletingLastPathComponent().path)
        #expect(leftovers.count == 1, "no partial files left behind")
    }

    @Test func aSummaryDoesNotReplaceWhatAlreadyExists() async throws {
        let (database, _, _) = try fixture.open()
        let pipeline = try pipeline(database)
        _ = try await dropTape(database)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE tape SET title = 'Mine', title_is_provisional = 0, description = 'My words', era = '1950s'")
        }

        try await runAll(pipeline, database)

        let tape = try await database.writer.read { db in try Tape.fetchOne(db)! }
        #expect(tape.title == "Mine")
        #expect(tape.description == "My words")
        #expect(tape.era == "1950s")
    }

    @Test func aFailingToolReportsItsError() async throws {
        let (database, _, _) = try fixture.open()
        var pipeline = try pipeline(database)
        pipeline.ffmpeg = try tool("ffmpeg-bad", "echo 'Invalid data found' >&2; exit 1")
        _ = try await dropTape(database)
        let job = try #require(try await database.writer.write { db in try JobStore.claimNext(db) })

        await #expect(throws: PipelineError.toolFailed("FFmpeg", "Invalid data found")) {
            try await pipeline.run(job, context: noContext)
        }
        let source = try await database.writer.read { db in try Source.fetchOne(db)! }
        #expect(source.prepPath == nil, "a failed prep leaves no record of prepared audio")
    }

    @Test func claudeNotBeingSignedInFailsTheJob() async throws {
        let (database, _, _) = try fixture.open()
        var pipeline = try pipeline(database)
        pipeline.claude = try tool("claude-signed-out", #"""
            cat > /dev/null
            echo '{"is_error":true,"subtype":"success","result":"Not logged in · Please run /login"}'
            """#)
        _ = try await dropTape(database)
        for _ in 0..<2 {
            let job = try #require(try await database.writer.write { db in try JobStore.claimNext(db) })
            try await pipeline.run(job, context: noContext)
            try await database.writer.write { db in try JobStore.complete(db, jobID: job.id!) }
        }
        let job = try #require(try await database.writer.write { db in try JobStore.claimNext(db) })

        await #expect(throws: SummaryError.claudeReported("Not logged in · Please run /login")) {
            try await pipeline.run(job, context: noContext)
        }
    }

    @Test func editedTranscriptsAreNeverOverwritten() async throws {
        let (database, _, _) = try fixture.open()
        let pipeline = try pipeline(database)
        _ = try await dropTape(database)
        let prep = try #require(try await database.writer.write { db in try JobStore.claimNext(db) })
        try await pipeline.run(prep, context: noContext)
        try await database.writer.write { db in
            try JobStore.complete(db, jobID: prep.id!)
            try db.execute(sql: "INSERT INTO segment (source_id, start_time, end_time, text, edited) VALUES (?, 0, 1, 'My fix', 1)", arguments: [prep.sourceId])
        }
        let transcribe = try #require(try await database.writer.write { db in try JobStore.claimNext(db) })

        await #expect(throws: PipelineError.wouldOverwriteEdits) {
            try await pipeline.run(transcribe, context: noContext)
        }
        let text = try await database.writer.read { db in try String.fetchAll(db, sql: "SELECT text FROM segment") }
        #expect(text == ["My fix"])
    }

    @Test func aRealFFmpegRunProducesWhisperReadyAudio() async throws {
        let (database, _, _) = try fixture.open()
        var pipeline = try pipeline(database)
        pipeline.ffmpeg = KnownTools.ffmpeg
        _ = try await dropTape(database)
        let prep = try #require(try await database.writer.write { db in try JobStore.claimNext(db) })

        try await pipeline.run(prep, context: noContext)

        let source = try await database.writer.read { db in try Source.fetchOne(db)! }
        let details = try await probeAudio(fixture.library.library.appending(path: source.prepPath!))
        #expect(details.sampleRate == 16000)
        #expect(details.channels == 1)
        #expect(details.bitDepth == 16)
    }
}

@Suite struct DropImporterTests {
    let fixture: BackupFixture
    let drops: URL

    init() throws {
        fixture = try BackupFixture()
        drops = fixture.library.library.deletingLastPathComponent().appending(path: "drops", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drops, withIntermediateDirectories: true)
    }

    private func wav(_ name: String, in folder: URL? = nil, seed: String? = nil) throws -> URL {
        let directory = folder ?? drops
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try BackupFixture.wav(seconds: 1, seed: seed ?? name).write(to: url)
        return url
    }

    private func importer(_ database: AppDatabase) -> DropImporter {
        DropImporter(database: database, paths: fixture.library) { _ in true }
    }

    private func shelf(_ database: AppDatabase) async throws -> [ShelfTape] {
        try await database.writer.read { db in try Library.fetchShelf(db) }
    }

    @Test func aFileBecomesATapeWithAReadOnlyCopy() async throws {
        let (database, _, _) = try fixture.open()
        let file = try wav("sunday_service.wav")
        let before = try Data(contentsOf: file)

        let summary = await importer(database).add([file])

        #expect(summary.added == ["sunday service"])
        let tape = try #require(try await shelf(database).first)
        let master = fixture.library.library.appending(path: tape.items[0].source.masterPath)
        #expect(FileManager.default.fileExists(atPath: master.path))
        #expect(!FileManager.default.isWritableFile(atPath: master.path))
        #expect(try Data(contentsOf: file) == before, "the original stays where it was, unchanged")
        #expect(tape.items[0].source.sha256?.count == 64)
    }

    @Test func aFolderBecomesOneTapeWithTracksInNaturalOrder() async throws {
        let (database, _, _) = try fixture.open()
        let folder = drops.appending(path: "Accordion Reel", directoryHint: .isDirectory)
        for name in ["track 10.wav", "track 2.wav", "track 1.wav"] { _ = try wav(name, in: folder) }
        try "Pueblo, 1963".write(to: folder.appending(path: "context.txt"), atomically: true, encoding: .utf8)
        try "not audio".write(to: folder.appending(path: "notes.pdf"), atomically: true, encoding: .utf8)

        let summary = await importer(database).add([folder])

        #expect(summary.added == ["Accordion Reel"])
        let tape = try #require(try await shelf(database).first)
        #expect(tape.items.map(\.name) == ["track 1", "track 2", "track 10"])
        #expect(tape.tape.context == "Pueblo, 1963")
        #expect(!tape.tape.titleIsProvisional, "a folder name is deliberate")
    }

    @Test func aFileCanHaveItsOwnContext() async throws {
        let (database, _, _) = try fixture.open()
        let file = try wav("call.wav")
        try "Marty's phone".write(to: file.appendingPathExtension("context.txt"), atomically: true, encoding: .utf8)

        _ = await importer(database).add([file])

        #expect(try await shelf(database).first?.tape.context == "Marty's phone")
    }

    @Test func theSameAudioIsNotAddedTwice() async throws {
        let (database, _, _) = try fixture.open()
        let first = try wav("original.wav", seed: "same")
        let second = try wav("renamed copy.wav", seed: "same")

        let summary = await importer(database).add([first, second])

        #expect(summary.added == ["original"])
        #expect(summary.alreadyInLibrary == ["renamed copy.wav"])
        #expect(try await shelf(database).count == 1)
    }

    @Test func thingsThatAreNotAudioAreReported() async throws {
        let (database, _, _) = try fixture.open()
        let text = drops.appending(path: "notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        let fake = drops.appending(path: "fake.wav")
        try "not really audio".write(to: fake, atomically: true, encoding: .utf8)
        let empty = drops.appending(path: "empty folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let summary = await importer(database).add([text, fake, empty])

        #expect(Set(summary.notAudio) == ["notes.txt", "fake.wav", "empty folder"])
        #expect(try await shelf(database).isEmpty)
        let masters = try FileManager.default.contentsOfDirectory(atPath: fixture.library.masters.path)
        #expect(masters.isEmpty, "no empty tape folders left behind")
    }

    @Test func aNewTapeQueuesTheFullPipeline() async throws {
        let (database, _, _) = try fixture.open()
        _ = await importer(database).add([try wav("a.wav")])

        let types = try await database.writer.read { db in
            try Job.order(Column("id")).fetchAll(db).map(\.type)
        }
        #expect(types == [.prep, .transcribe, .summarize, .peaks])
    }
}
