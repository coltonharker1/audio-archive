import Foundation
import GRDB
import Testing
@testable import RemanenceCore

@Suite struct SegmentLookupTests {
    private func segments(_ starts: [Double]) -> [Segment] {
        starts.enumerated().map { index, start in
            Segment(id: Int64(index), sourceId: 1, startTime: start, endTime: start + 1, text: "line")
        }
    }

    @Test func findsTheLineAtATime() {
        let list = segments([2, 5, 9])
        #expect(segmentIndex(at: 0, in: list) == nil)
        #expect(segmentIndex(at: 2, in: list) == 0)
        #expect(segmentIndex(at: 4.9, in: list) == 0)
        #expect(segmentIndex(at: 5, in: list) == 1)
        #expect(segmentIndex(at: 100, in: list) == 2)
    }

    @Test func handlesAnEmptyTranscript() {
        #expect(segmentIndex(at: 3, in: []) == nil)
    }
}

@Suite struct TranscriptStoreTests {
    let database: AppDatabase
    let library: Library
    let source: Int64
    let tape: Int64

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "remanence-transcripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = LibraryPaths(library: root, support: root)
        try paths.createDirectories()
        database = try AppDatabase.open(at: paths.database)
        library = Library(database: database, paths: paths)

        (tape, source) = try database.writer.write { db in
            var tape = Tape(uuid: "t", catalogNumber: "RA-004", title: "Phone Call", description: "A call about the weather.", createdAt: Date())
            try tape.insert(db)
            var source = Source(tapeId: tape.id!, position: 0, masterPath: "m.wav", sha256: "s", duration: 60, transcriptModel: "base")
            try source.insert(db)
            var track = Track(sourceId: source.id!, name: "Phone Call")
            try track.insert(db)
            for (start, text) in [(0.0, "Carl was in a bad wreck."), (5.0, "We've had tornadoes throughout Oklahoma."), (10.0, "Have a nice weekend.")] {
                var segment = Segment(sourceId: source.id!, startTime: start, endTime: start + 5, text: text)
                try segment.insert(db)
            }
            return (tape.id!, source.id!)
        }
    }

    private func segments() async throws -> [Segment] {
        try await database.writer.read { [source] db in
            try Segment.filter(Column("source_id") == source).order(Column("start_time")).fetchAll(db)
        }
    }

    @Test func editingALineKeepsItsTimingAndMarksIt() async throws {
        let line = try await segments()[0]
        try await library.updateSegment(id: line.id!, text: "  Carl had a bad wreck.  ")

        let updated = try await segments()[0]
        #expect(updated.text == "Carl had a bad wreck.")
        #expect(updated.edited)
        #expect(updated.startTime == line.startTime)
    }

    @Test func savingWithoutAChangeDoesNotMarkItEdited() async throws {
        let line = try await segments()[0]
        try await library.updateSegment(id: line.id!, text: line.text)
        #expect(try await segments()[0].edited == false)
    }

    @Test func aLineCannotBeEmptied() async throws {
        let line = try await segments()[0]
        await #expect(throws: TranscriptError.emptyLine) {
            try await library.updateSegment(id: line.id!, text: "   ")
        }
        #expect(try await segments()[0].text == line.text)
    }

    @Test func searchFindsEditedTextAndForgetsTheOld() async throws {
        let line = try await segments()[0]
        try await library.updateSegment(id: line.id!, text: "Karl had a bad accident.")

        #expect(try await library.search("wreck").isEmpty)
        #expect(try await library.search("accident").first?.moments.first?.id == line.id)
    }

    @Test func searchReturnsTheExactMoment() async throws {
        let results = try await library.search("tornado")
        let result = try #require(results.first)
        #expect(result.tapeID == tape)
        #expect(result.catalogNumber == "RA-004")
        let moment = try #require(result.moments.first)
        #expect(moment.time == 5)
        #expect(moment.sourceID == source)
        #expect(moment.snippet.contains("\(SearchHighlight.start)tornadoes\(SearchHighlight.end)"))
    }

    @Test func searchMatchesPrefixesAndAllWordsInAnyCase() async throws {
        #expect(try await library.search("TORN").first?.moments.count == 1)
        #expect(try await library.search("oklahoma tornadoes").first?.moments.count == 1)
        #expect(try await library.search("oklahoma wreck").allSatisfy { $0.moments.isEmpty })
    }

    @Test func quotesMatchAnExactPhrase() async throws {
        #expect(try await library.search("\"nice weekend\"").first?.moments.count == 1)
        #expect(try await library.search("\"weekend nice\"").allSatisfy { $0.moments.isEmpty })
    }

    @Test func oddInputDoesNotBreakSearch() async throws {
        for text in ["", "   ", "\"", "\"\"", "*", "(", "AND", "NEAR(", "'; DROP TABLE tape;--", "100%", "a_b", "-"] {
            _ = try await library.search(text)
        }
        #expect(try await library.search("tornado").count == 1, "the library is unharmed")
    }

    @Test func searchAlsoFindsTapeDetails() async throws {
        let titleResults = try await library.search("Phone Call")
        let byTitle = try #require(titleResults.first)
        #expect(byTitle.matchedDetails)
        #expect(byTitle.moments.isEmpty)

        let descriptionResults = try await library.search("weather")
        let byDescription = try #require(descriptionResults.first)
        #expect(byDescription.matchedDetails)
    }

    @Test func percentAndUnderscoreAreLiteralInDetails() async throws {
        #expect(try await library.search("%").isEmpty)
        #expect(try await library.search("_").isEmpty)
    }

    @Test func contextAndApprovalAreSaved() async throws {
        try await library.setContext(tapeID: tape, context: "  From Marty's estate.  ")
        try await library.setApproved(tapeID: tape, approved: true)
        var stored = try await database.writer.read { [tape] db in try Tape.fetchOne(db, key: tape)! }
        #expect(stored.context == "From Marty's estate.")
        #expect(stored.approvedAt != nil)

        try await library.setContext(tapeID: tape, context: "   ")
        try await library.setApproved(tapeID: tape, approved: false)
        stored = try await database.writer.read { [tape] db in try Tape.fetchOne(db, key: tape)! }
        #expect(stored.context == nil)
        #expect(stored.approvedAt == nil)
    }

    @Test func requestingASummaryQueuesOnePerTrackOnce() async throws {
        try await library.requestSummary(tapeID: tape)
        try await library.requestSummary(tapeID: tape)
        let jobs = try await database.writer.read { db in try Job.filter(Column("type") == "summarize").fetchAll(db) }
        #expect(jobs.count == 1)
        #expect(jobs[0].status == .pending)
    }

    @Test func aComparisonLeavesTheRealTranscriptAlone() async throws {
        let before = try await segments()
        try await library.requestComparison(sourceID: source, model: "medium")
        try await library.requestComparison(sourceID: source, model: "medium")

        let jobs = try await database.writer.read { db in try Job.fetchAll(db) }
        #expect(jobs.count == 1, "only one comparison at a time")
        #expect(jobs[0].candidate)
        #expect(jobs[0].model == "medium")
        #expect(try await segments() == before)
    }

    private func storeCandidate() async throws {
        let json = String(decoding: try JSONEncoder().encode([
            TranscriptLine(start: 0, end: 5, text: "Call was in a bad wreck."),
        ]), as: UTF8.self)
        try await database.writer.write { [source] db in
            try db.execute(
                sql: "INSERT INTO transcript_candidate (source_id, model, segments) VALUES (?, 'medium', ?)",
                arguments: [source, json]
            )
        }
    }

    @Test func adoptingReplacesTheTranscriptAndSearchFollows() async throws {
        try await storeCandidate()
        try await library.adoptCandidate(sourceID: source)

        let lines = try await segments()
        #expect(lines.map(\.text) == ["Call was in a bad wreck."])
        #expect(try await library.search("tornado").isEmpty)
        #expect(try await library.search("call").first?.moments.count == 1)

        let (model, left) = try await database.writer.read { [source] db in
            (
                try String.fetchOne(db, sql: "SELECT transcript_model FROM source WHERE id = ?", arguments: [source]),
                try Int.fetchOne(db, sql: "SELECT count(*) FROM transcript_candidate")
            )
        }
        #expect(model == "medium")
        #expect(left == 0)
    }

    @Test func keepingTheCurrentTranscriptChangesNothing() async throws {
        let before = try await segments()
        try await storeCandidate()
        try await library.discardCandidate(sourceID: source)
        #expect(try await segments() == before)
        await #expect(throws: TranscriptError.noCandidate) {
            try await library.adoptCandidate(sourceID: source)
        }
    }

    private func claim(at time: Date) async throws -> Job? {
        try await database.writer.write { db in try JobStore.claimNext(db, now: time) }
    }

    @Test func aFailedComparisonDoesNotBlockASummary() async throws {
        try await library.requestComparison(sourceID: source, model: "medium")
        try await library.requestSummary(tapeID: tape)

        // The comparison is older, so it's claimed first. The summary can run too.
        let first = try #require(try await claim(at: Date()))
        #expect(first.candidate)
        let second = try await claim(at: Date())
        #expect(second?.type == .summarize)

        var attempt = first
        var time = Date()
        while attempt.attempt < attempt.maxAttempts {
            try await database.writer.write { [attempt, time] db in try JobStore.fail(db, jobID: attempt.id!, message: "boom", now: time) }
            time = time.addingTimeInterval(1000)
            attempt = try #require(try await claim(at: time))
        }
        try await database.writer.write { [attempt, time] db in try JobStore.fail(db, jobID: attempt.id!, message: "boom", now: time) }

        let summarize = try await database.writer.read { db in try Job.filter(Column("type") == "summarize").fetchOne(db) }
        #expect(summarize?.status == .running, "a comparison's failure stays its own")
    }

    @Test func updatesArriveWhenATranscriptChanges() async throws {
        var updates = library.readAlongUpdates(sourceID: source).makeAsyncIterator()
        let firstUpdate = try await updates.next()
        let first = try #require(firstUpdate)
        #expect(first.segments.count == 3)
        #expect(first.transcriptModel == "base")
        #expect(first.track?.name == "Phone Call")
        #expect(!first.isComparing)

        try await library.updateSegment(id: first.segments[0].id!, text: "Changed.")
        #expect(try await updates.next()?.segments[0].text == "Changed.")
    }

    @Test func summaryDetailsAreReadFromStoredJSON() {
        let track = Track(sourceId: 1, summary: #"{"summary_short":"Short","people":["Carl","Marty"],"places":["Tulsa"],"organizations":["Carl"]}"#)
        #expect(track.summaryDetails?.summaryShort == "Short")
        #expect(track.summaryDetails?.mentioned == ["Carl", "Marty", "Tulsa"])
        #expect(Track(sourceId: 1, summary: "not json").summaryDetails == nil)
    }

    @Test func comparisonUsesTheOtherModel() {
        #expect(Library.comparisonModel(for: "base") == "medium")
        #expect(Library.comparisonModel(for: "medium") == "base")
        #expect(Library.comparisonModel(for: nil) == "medium")
    }
}

@Suite struct TranscriptComparisonTests {
    private func current(_ lines: [(Double, String)]) -> [Segment] {
        lines.map { Segment(sourceId: 1, startTime: $0.0, endTime: $0.0 + 1, text: $0.1) }
    }

    private func candidate(_ lines: [(Double, String)]) -> [TranscriptLine] {
        lines.map { TranscriptLine(start: $0.0, end: $0.0 + 1, text: $0.1) }
    }

    @Test func identicalTranscriptsHaveNoChanges() {
        #expect(TranscriptComparison.changes(current: current([(0, "Hello there")]), candidate: candidate([(0, "Hello there")])).isEmpty)
    }

    @Test func caseAndPunctuationDoNotCount() {
        #expect(TranscriptComparison.changes(current: current([(0, "Hello, there.")]), candidate: candidate([(0, "hello there")])).isEmpty)
    }

    @Test func aChangedWordIsFoundInContext() throws {
        let changes = TranscriptComparison.changes(
            current: current([(0, "Well then"), (7, "Carl was in a bad wreck")]),
            candidate: candidate([(0, "Well then"), (7, "Call was in a bad wreck")]),
            contextWords: 2
        )
        let change = try #require(changes.first)
        #expect(changes.count == 1)
        #expect(change.time == 7)
        #expect(change.before == "Well then")
        #expect(change.current == "Carl")
        #expect(change.candidate == "Call")
        #expect(change.after == "was in")
    }

    @Test func differentLineBreaksDoNotCount() {
        let changes = TranscriptComparison.changes(
            current: current([(0, "one two three"), (5, "four five")]),
            candidate: candidate([(0, "one two"), (3, "three four five")])
        )
        #expect(changes.isEmpty)
    }

    @Test func nearbyChangesMerge() throws {
        let changes = TranscriptComparison.changes(
            current: current([(0, "the film sat alongside me today")]),
            candidate: candidate([(0, "the friend sat beside me today")])
        )
        let change = try #require(changes.first)
        #expect(changes.count == 1)
        #expect(change.current == "film sat alongside")
        #expect(change.candidate == "friend sat beside")
    }

    @Test func distantChangesStaySeparate() {
        let filler = "a b c d e f g h i j"
        let changes = TranscriptComparison.changes(
            current: current([(0, "one \(filler) two")]),
            candidate: candidate([(0, "uno \(filler) dos")])
        )
        #expect(changes.map(\.current) == ["one", "two"])
        #expect(changes.map(\.candidate) == ["uno", "dos"])
    }

    @Test func addedAndRemovedWordsAreFound() {
        let added = TranscriptComparison.changes(current: current([(0, "a b c d e f")]), candidate: candidate([(0, "a b new c d e f")]))
        #expect(added.first?.current == "")
        #expect(added.first?.candidate == "new")

        let removed = TranscriptComparison.changes(current: current([(0, "a b old c d e f")]), candidate: candidate([(0, "a b c d e f")]))
        #expect(removed.first?.current == "old")
        #expect(removed.first?.candidate == "")
    }

    @Test func changesAtTheVeryEndAreFound() {
        let changes = TranscriptComparison.changes(current: current([(0, "a b c")]), candidate: candidate([(0, "a b c d")]))
        #expect(changes.first?.candidate == "d")
    }

    @Test func emptySidesWork() {
        #expect(TranscriptComparison.changes(current: [], candidate: []).isEmpty)
        #expect(TranscriptComparison.changes(current: [], candidate: candidate([(2, "hello")])).first?.candidate == "hello")
        #expect(TranscriptComparison.changes(current: current([(2, "hello")]), candidate: []).first?.current == "hello")
    }
}

@Suite struct CandidatePipelineTests {
    @Test func aComparisonRunIsStoredApartEvenWithEdits() async throws {
        let fixture = try BackupFixture()
        let (database, _, _) = try fixture.open()
        let tools = fixture.library.library.deletingLastPathComponent().appending(path: "tools", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let whisper = tools.appending(path: "whisper")
        try #"""
            #!/bin/sh
            while [ $# -gt 0 ]; do
              if [ "$1" = "--output-file" ]; then base="$2"; fi
              shift
            done
            cat > "$base.json" <<'JSON'
            {"transcription":[{"offsets":{"from":0,"to":2000},"text":" Better words. "}]}
            JSON
            """#.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.drop { $0 == " " } }.joined(separator: "\n")
            .write(to: whisper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: whisper.path)

        var pipeline = Pipeline(database: database, paths: fixture.library)
        pipeline.whisper = whisper
        let prepared = fixture.library.processed.appending(path: "p.wav")
        try BackupFixture.wav(seconds: 1, seed: "p").write(to: prepared)

        let source: Int64 = try await database.writer.write { db in
            var tape = Tape(uuid: "t", title: "T", createdAt: Date())
            try tape.insert(db)
            var source = Source(tapeId: tape.id!, position: 0, masterPath: "m.wav", sha256: "s", prepPath: "processed/p.wav", duration: 1, transcriptModel: "base")
            try source.insert(db)
            var segment = Segment(sourceId: source.id!, startTime: 0, endTime: 1, text: "My fix", edited: true)
            try segment.insert(db)
            return source.id!
        }
        let library = Library(database: database, paths: fixture.library)
        try await library.requestComparison(sourceID: source, model: "medium")
        let claimed: Job? = try await database.writer.write { db in try JobStore.claimNext(db) }
        let job = try #require(claimed)

        try await pipeline.run(job, context: JobContext(reportProgress: { _ in }, reportPID: { _ in }))

        var updates = library.readAlongUpdates(sourceID: source).makeAsyncIterator()
        let update = try await updates.next()
        let result = try #require(update)
        #expect(result.segments.map(\.text) == ["My fix"], "your edits stay until you choose")
        #expect(result.transcriptModel == "base")
        #expect(result.candidate?.model == "medium")
        #expect(result.candidate?.lines == [TranscriptLine(start: 0, end: 2, text: "Better words.")])
    }
}
