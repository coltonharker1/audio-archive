import Foundation
import GRDB

/// What a running job can report back while it works.
public struct JobContext: Sendable {
    public let reportProgress: @Sendable (Double) -> Void
    public let reportPID: @Sendable (Int32) -> Void
}

/// Runs jobs from the durable queue. All state lives in the database, so this holds
/// only what's in flight, and a new instance picks up exactly where one left off.
public actor JobQueue {
    public typealias Handler = @Sendable (Job, JobContext) async throws -> Void

    private let database: AppDatabase
    private let handler: Handler
    private let tools: [URL]
    private let pollInterval: Duration
    private let onProgress: @Sendable (Int64, Double) -> Void

    private var running: [Int64: Task<Void, Never>] = [:]
    private var loop: Task<Void, Never>?
    private var isPaused = false
    private var isAsleep = false
    private var sleepCount = 0
    private var activity: NSObjectProtocol?

    public init(
        database: AppDatabase,
        tools: [URL] = [],
        pollInterval: Duration = .seconds(1),
        onProgress: @escaping @Sendable (Int64, Double) -> Void = { _, _ in },
        handler: @escaping Handler
    ) {
        self.database = database
        self.tools = tools
        self.pollInterval = pollInterval
        self.onProgress = onProgress
        self.handler = handler
    }

    /// Recovers anything interrupted last time, then begins working.
    public func start() async throws {
        guard loop == nil else { return }
        let leftovers = try await database.writer.write { db in try JobStore.resetInterrupted(db) }
        for pid in leftovers {
            stopOrphanedTool(pid: pid, allowedTools: tools)
        }
        loop = Task { await runLoop() }
    }

    /// Stops running tools and returns their jobs to the queue.
    public func stop() async {
        loop?.cancel()
        await loop?.value
        loop = nil

        let tasks = Array(running.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
    }

    /// Stops new jobs from starting, leaving running ones to finish. Recording uses
    /// this so transcription can't cause dropouts.
    public func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    /// Holds new jobs while the Mac sleeps. It wakes briefly for maintenance with
    /// no usable network, and a job started then would fail through no fault of its own.
    public func systemWillSleep() {
        isAsleep = true
        sleepCount += 1
    }

    public func systemDidWake() {
        isAsleep = false
    }

    private func runLoop() async {
        while !Task.isCancelled {
            if !isPaused && !isAsleep { startReadyJobs() }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func startReadyJobs() {
        do {
            while let job = try database.writer.write({ db in try JobStore.claimNext(db) }), let id = job.id {
                beginActivityIfNeeded()
                running[id] = Task(priority: .userInitiated) { await self.run(job, id: id) }
            }
        } catch {
            // Claiming only fails if the database does. The next tick tries again.
        }
    }

    private func run(_ job: Job, id: Int64) async {
        let database = database
        let onProgress = onProgress
        let context = JobContext(
            reportProgress: { onProgress(id, $0) },
            reportPID: { pid in
                try? database.writer.write { db in try JobStore.recordPID(db, jobID: id, pid: pid) }
            }
        )

        let sleepsAtStart = sleepCount
        let outcome: Result<Void, Error>
        do {
            try await handler(job, context)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        // A failure across a sleep usually means lost network or a frozen process,
        // so it goes back in the queue rather than counting against the job.
        let wasStopped = Task.isCancelled || sleepCount != sleepsAtStart

        // GRDB refuses to write from a cancelled task, which would leave a stopped
        // job marked running. So the result is saved from outside this task.
        await Task.detached {
            try? await database.writer.write { db in
                switch outcome {
                case .success:
                    try JobStore.complete(db, jobID: id)
                case .failure(let error) where wasStopped || error is CancellationError:
                    try JobStore.requeue(db, jobID: id)
                case .failure(let error):
                    try JobStore.fail(db, jobID: id, message: error.localizedDescription)
                }
            }
        }.value

        running[id] = nil
        endActivityIfIdle()
    }

    /// Without this, macOS can throttle the app with App Nap once its window is
    /// hidden, the same kind of slowdown as the launchd QoS bug. It also keeps the
    /// Mac from idle-sleeping halfway through a long batch.
    private func beginActivityIfNeeded() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Processing tapes"
        )
    }

    private func endActivityIfIdle() {
        guard running.isEmpty, let token = activity else { return }
        ProcessInfo.processInfo.endActivity(token)
        activity = nil
    }
}
