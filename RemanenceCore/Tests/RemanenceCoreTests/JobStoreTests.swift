import Foundation
import GRDB
import Testing
@testable import RemanenceCore

@Suite struct JobStoreTests {
    let database: AppDatabase
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "remanence-jobs-\(UUID().uuidString)/library.sqlite")
        database = try AppDatabase.open(at: path)
    }

    /// A source with its full pipeline queued.
    @discardableResult
    private func addPipeline(_ name: String = UUID().uuidString) throws -> (source: Int64, track: Int64) {
        try database.writer.write { db in
            var tape = Tape(uuid: name, title: name, createdAt: start)
            try tape.insert(db)
            var source = Source(tapeId: tape.id!, position: 0, masterPath: "m/\(name).wav", sha256: name, duration: 60)
            try source.insert(db)
            var track = Track(sourceId: source.id!, name: name)
            try track.insert(db)
            try JobStore.enqueuePipeline(db, sourceID: source.id!, trackID: track.id!, model: "base", now: start)
            return (source.id!, track.id!)
        }
    }

    private func claim(at date: Date? = nil) throws -> Job? {
        try database.writer.write { db in try JobStore.claimNext(db, now: date ?? start) }
    }

    private func finish(_ job: Job) throws {
        try database.writer.write { db in try JobStore.complete(db, jobID: job.id!, now: start) }
    }

    private func fail(_ job: Job, at date: Date? = nil) throws {
        try database.writer.write { db in try JobStore.fail(db, jobID: job.id!, message: "boom", now: date ?? start) }
    }

    private func job(_ id: Int64?) throws -> Job? {
        try database.writer.read { db in try Job.fetchOne(db, key: id!) }
    }

    @Test func stagesRunInOrder() throws {
        try addPipeline()

        let prep = try #require(try claim())
        #expect(prep.type == .prep)
        #expect(prep.status == .running)
        #expect(prep.attempt == 1)
        #expect(try claim() == nil, "transcribe must wait for prep")

        try finish(prep)
        let transcribe = try #require(try claim())
        #expect(transcribe.type == .transcribe)
        #expect(try claim() == nil, "summarize must wait for transcribe")

        try finish(transcribe)
        let summarize = try #require(try claim())
        #expect(summarize.type == .summarize)
        try finish(summarize)
        #expect(try claim() == nil)
    }

    @Test func onlyOneTranscribeRunsAtATime() throws {
        let first = try addPipeline("a")
        let second = try addPipeline("b")
        try finish(try #require(try claim()))

        let transcribe = try #require(try claim())
        #expect(transcribe.type == .transcribe)
        #expect(transcribe.sourceId == first.source)

        // The other tape's prep can run alongside, but its transcribe has to wait.
        let otherPrep = try #require(try claim())
        #expect(otherPrep.type == .prep)
        #expect(otherPrep.sourceId == second.source)
        try finish(otherPrep)
        #expect(try claim() == nil, "a second transcribe must wait")

        try finish(transcribe)
        let next = try #require(try claim())
        #expect(next.type == .transcribe || next.type == .summarize)
        let other = try #require(try claim())
        #expect([next, other].contains { $0.type == .transcribe && $0.sourceId == second.source })
    }

    @Test func prepAndSummarizeHaveTheirOwnLimits() throws {
        for name in ["a", "b", "c"] { try addPipeline(name) }
        #expect(try claim()?.type == .prep)
        #expect(try claim()?.type == .prep)
        #expect(try claim() == nil, "only two preps at once")
    }

    @Test func aFailureRetriesAfterADelay() throws {
        try addPipeline()
        let prep = try #require(try claim())
        try fail(prep)

        let waiting = try #require(try job(prep.id))
        #expect(waiting.status == .pending)
        #expect(waiting.error == "boom")
        #expect(try claim(at: start.addingTimeInterval(29)) == nil, "still backing off")

        let retried = try #require(try claim(at: start.addingTimeInterval(31)))
        #expect(retried.id == prep.id)
        #expect(retried.attempt == 2)
    }

    @Test func exhaustingRetriesFailsTheJobAndLaterStages() throws {
        let ids = try addPipeline()
        var prep = try #require(try claim())
        var time = start
        while prep.attempt < prep.maxAttempts {
            try fail(prep, at: time)
            time = time.addingTimeInterval(1000)
            prep = try #require(try claim(at: time))
        }
        try fail(prep, at: time)

        #expect(try job(prep.id)?.status == .failed)
        let others = try database.writer.read { db in
            try Job.filter(Column("id") != prep.id!).fetchAll(db)
        }
        #expect(others.count == 2)
        #expect(others.allSatisfy { $0.status == .failed })
        #expect(try claim(at: time.addingTimeInterval(1000)) == nil)

        let shelf = try database.writer.read { db in try JobStore.statuses(db) }
        let tape = try database.writer.read { db in try Int64.fetchOne(db, sql: "SELECT tape_id FROM source WHERE id = ?", arguments: [ids.source]) }
        #expect(shelf[tape!] == .failed("boom"), "the real cause is shown, not the knock-on")
    }

    @Test func aFailedTranscribeOnlyBlocksTheSummary() throws {
        try addPipeline()
        try finish(try #require(try claim()))
        var transcribe = try #require(try claim())
        var time = start
        while transcribe.attempt < transcribe.maxAttempts {
            try fail(transcribe, at: time)
            time = time.addingTimeInterval(1000)
            transcribe = try #require(try claim(at: time))
        }
        try fail(transcribe, at: time)

        let statuses = try database.writer.read { db in
            try Job.order(Column("id")).fetchAll(db).map(\.status)
        }
        #expect(statuses == [.complete, .failed, .failed])
    }

    @Test func aStoppedJobKeepsItsAttempts() throws {
        try addPipeline()
        let prep = try #require(try claim())
        try database.writer.write { db in try JobStore.requeue(db, jobID: prep.id!) }

        let requeued = try #require(try job(prep.id))
        #expect(requeued.status == .pending)
        #expect(requeued.attempt == 0)
        #expect(requeued.nextAttemptAt == nil)
        #expect(try claim()?.id == prep.id, "no backoff after a stop")
    }

    @Test func interruptedJobsReturnToTheQueueWithTheirProcessIDs() throws {
        try addPipeline()
        let prep = try #require(try claim())
        try database.writer.write { db in try JobStore.recordPID(db, jobID: prep.id!, pid: 4242) }

        let pids = try database.writer.write { db in try JobStore.resetInterrupted(db) }
        #expect(pids == [4242])

        let reset = try #require(try job(prep.id))
        #expect(reset.status == .pending)
        #expect(reset.attempt == 0)
        #expect(reset.pid == nil)
    }

    @Test func retryGivesFailedJobsAFreshStart() throws {
        let ids = try addPipeline()
        var prep = try #require(try claim())
        var time = start
        while prep.attempt < prep.maxAttempts {
            try fail(prep, at: time)
            time = time.addingTimeInterval(1000)
            prep = try #require(try claim(at: time))
        }
        try fail(prep, at: time)

        try database.writer.write { db in
            let tape = try Int64.fetchOne(db, sql: "SELECT tape_id FROM source WHERE id = ?", arguments: [ids.source])!
            try JobStore.retry(db, tapeID: tape)
        }

        let jobs = try database.writer.read { db in try Job.fetchAll(db) }
        #expect(jobs.allSatisfy { $0.status == .pending && $0.attempt == 0 && $0.error == nil })
        #expect(try claim()?.type == .prep)
    }

    @Test func statusReflectsTheMostActiveJob() throws {
        let ids = try addPipeline()
        let tape = try database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT tape_id FROM source WHERE id = ?", arguments: [ids.source])!
        }
        func status() throws -> TapeStatus? {
            try database.writer.read { db in try JobStore.statuses(db)[tape] }
        }

        #expect(try status() == .waiting)
        let prep = try #require(try claim())
        #expect(try status() == .working(type: .prep, jobID: prep.id!))
        try finish(prep)
        #expect(try status() == .waiting)
        let transcribe = try #require(try claim())
        #expect(try status() == .working(type: .transcribe, jobID: transcribe.id!))
        try finish(transcribe)
        try finish(try #require(try claim()))
        #expect(try status() == nil)
    }

    @Test func existingTapesGetTranscriptsButNoSummaries() throws {
        try database.writer.write { db in
            var tape = Tape(uuid: "reel", title: "Reel", medium: "7\" Reel-to-Reel", createdAt: start)
            try tape.insert(db)
            var withPrep = Source(tapeId: tape.id!, position: 0, masterPath: "a.wav", sha256: "a", prepPath: "a.prep.wav", duration: 60)
            try withPrep.insert(db)
            var noPrep = Source(tapeId: tape.id!, position: 1, masterPath: "b.wav", sha256: "b", duration: 60)
            try noPrep.insert(db)

            var micro = Tape(uuid: "micro", title: "Micro", medium: "Microcassette", createdAt: start)
            try micro.insert(db)
            var call = Source(tapeId: micro.id!, position: 0, masterPath: "c.wav", sha256: "c", prepPath: "c.prep.wav", duration: 60)
            try call.insert(db)

            var done = Tape(uuid: "done", title: "Done", createdAt: start)
            try done.insert(db)
            var finished = Source(tapeId: done.id!, position: 0, masterPath: "d.wav", sha256: "d", prepPath: "d.prep.wav", duration: 60, transcriptModel: "base")
            try finished.insert(db)

            try JobStore.enqueueMissingTranscripts(db, now: start) { _ in true }
        }

        let jobs = try database.writer.read { db in try Job.order(Column("id")).fetchAll(db) }
        #expect(jobs.filter { $0.type == .summarize }.isEmpty)
        #expect(jobs.filter { $0.type == .prep }.count == 1, "only the source with no prepared audio")
        #expect(jobs.filter { $0.type == .transcribe }.map(\.model) == ["medium", "medium", "base"])

        try database.writer.write { db in
            try JobStore.enqueueMissingTranscripts(db, now: start) { _ in true }
        }
        let again = try database.writer.read { db in try Job.fetchCount(db) }
        #expect(again == jobs.count, "running it again adds nothing")
    }

    @Test func modelChoiceFollowsTheFormat() {
        #expect(WhisperModel.preferred(for: .sevenInchReel) { _ in true } == "medium")
        #expect(WhisperModel.preferred(for: .fiveInchReel) { _ in true } == "medium")
        #expect(WhisperModel.preferred(for: .sevenInchReel) { _ in false } == "base")
        #expect(WhisperModel.preferred(for: .microcassette) { _ in true } == "base")
        #expect(WhisperModel.preferred(for: .unknown) { _ in true } == "base")
    }
}

@Suite struct JobQueueTests {
    let database: AppDatabase

    init() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "remanence-queue-\(UUID().uuidString)/library.sqlite")
        database = try AppDatabase.open(at: path)
        try database.writer.write { db in
            var tape = Tape(uuid: "t", title: "T", createdAt: Date())
            try tape.insert(db)
            var source = Source(tapeId: tape.id!, position: 0, masterPath: "m.wav", sha256: "s", duration: 60)
            try source.insert(db)
            var track = Track(sourceId: source.id!, name: "T")
            try track.insert(db)
            try JobStore.enqueuePipeline(db, sourceID: source.id!, trackID: track.id!, model: "base", now: Date())
        }
    }

    private func statuses() throws -> [JobStatus] {
        try database.writer.read { db in try Job.order(Column("id")).fetchAll(db).map(\.status) }
    }

    private func waitFor(_ condition: () throws -> Bool) async throws {
        for _ in 0..<400 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting")
    }

    @Test func runsAPipelineThroughToTheEnd() async throws {
        let order = Locked<[JobType]>([])
        let queue = JobQueue(database: database, pollInterval: .milliseconds(5)) { job, _ in
            order.mutate { $0.append(job.type) }
        }
        try await queue.start()
        try await waitFor { try statuses() == [.complete, .complete, .complete] }
        await queue.stop()
        #expect(order.value == [.prep, .transcribe, .summarize])
    }

    @Test func stoppingRequeuesWithoutUsingAnAttempt() async throws {
        let started = Locked(false)
        let queue = JobQueue(database: database, pollInterval: .milliseconds(5)) { _, _ in
            started.mutate { $0 = true }
            try await Task.sleep(for: .seconds(60))
        }
        try await queue.start()
        try await waitFor { started.value }
        await queue.stop()

        let prep = try #require(try await database.writer.read { db in try Job.order(Column("id")).fetchOne(db) })
        #expect(prep.status == .pending)
        #expect(prep.attempt == 0)
    }

    /// The crash test: a queue that vanishes mid-job leaves a running row behind,
    /// and the next one must finish everything.
    @Test func aNewQueueResumesAfterACrash() async throws {
        let claimed = try await database.writer.write { db in try JobStore.claimNext(db) }
        #expect(claimed?.status == .running)

        let queue = JobQueue(database: database, pollInterval: .milliseconds(5)) { _, _ in }
        try await queue.start()
        try await waitFor { try statuses() == [.complete, .complete, .complete] }
        await queue.stop()
    }

    @Test func aFailingJobIsRecorded() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let queue = JobQueue(database: database, pollInterval: .milliseconds(5)) { _, _ in throw Boom() }
        try await queue.start()
        try await waitFor {
            try database.writer.read { db in
                try Job.order(Column("id")).fetchOne(db)?.error == "boom"
            }
        }
        await queue.stop()
    }

    /// A closed lid once used up a summary's retries while the Mac was asleep.
    @Test func aFailureAcrossASystemSleepKeepsItsAttempts() async throws {
        struct NetworkGone: Error {}
        let started = Locked(false)
        let release = Locked(false)
        let queue = JobQueue(database: database, pollInterval: .milliseconds(5)) { _, _ in
            started.mutate { $0 = true }
            while !release.value { try await Task.sleep(for: .milliseconds(5)) }
            throw NetworkGone()
        }
        try await queue.start()
        try await waitFor { started.value }

        await queue.systemWillSleep()
        release.mutate { $0 = true }

        try await waitFor {
            try database.writer.read { db in
                try Job.order(Column("id")).fetchOne(db)?.status == .pending
            }
        }
        let prep = try #require(try await database.writer.read { db in try Job.order(Column("id")).fetchOne(db) })
        #expect(prep.attempt == 0)
        #expect(prep.error == nil)
        #expect(prep.nextAttemptAt == nil)
        await queue.stop()
    }

    @Test func nothingStartsWhileAsleep() async throws {
        let ran = Locked(0)
        let queue = JobQueue(database: database, pollInterval: .milliseconds(5)) { _, _ in
            ran.mutate { $0 += 1 }
        }
        await queue.systemWillSleep()
        try await queue.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(ran.value == 0)

        await queue.systemDidWake()
        try await waitFor { ran.value == 3 }
        await queue.stop()
    }

    @Test func recordingStopsRunningJobsWithoutUsingAttempts() async throws {
        let started = Locked(0)
        let queue = JobQueue(database: database, pollInterval: .milliseconds(5)) { _, _ in
            started.mutate { $0 += 1 }
            try await Task.sleep(for: .seconds(60))
        }
        try await queue.start()
        try await waitFor { started.value == 1 }

        await queue.suspendForRecording()

        let prep = try #require(try await database.writer.read { db in try Job.order(Column("id")).fetchOne(db) })
        #expect(prep.status == .pending)
        #expect(prep.attempt == 0)
        try await Task.sleep(for: .milliseconds(60))
        #expect(started.value == 1, "nothing restarts during a recording")

        await queue.setPaused(false)
        try await waitFor { started.value == 2 }
        await queue.stop()
    }

    @Test func pausingHoldsNewJobs() async throws {
        let ran = Locked(0)
        let queue = JobQueue(database: database, pollInterval: .milliseconds(5)) { _, _ in
            ran.mutate { $0 += 1 }
        }
        await queue.setPaused(true)
        try await queue.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(ran.value == 0)

        await queue.setPaused(false)
        try await waitFor { ran.value == 3 }
        await queue.stop()
    }
}
