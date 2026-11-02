import Darwin
import Foundation

public enum SubprocessError: LocalizedError, Equatable {
    case couldNotStart(String, Int32)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .couldNotStart(let tool, let code): "\(tool) couldn’t start: \(String(cString: strerror(code)))."
        case .timedOut(let tool): "\(tool) took too long and was stopped."
        }
    }
}

/// Runs pipeline tools so they can always be stopped.
///
/// Three lessons from the Go version are built in:
/// - Each tool gets its own process group, so stopping it stops its children too.
/// - Output goes to files rather than pipes. A leaked child holding a pipe open
///   once hung an overnight batch, and a file can't do that.
/// - Tools run at user-initiated QoS. Background QoS made Whisper about 200× slower.
public func runSubprocess(
    _ executable: URL,
    arguments: [String],
    standardInput: URL? = nil,
    standardOutput: URL,
    standardError: URL,
    timeout: Duration?,
    onSpawn: @Sendable (Int32) -> Void = { _ in }
) async throws -> Int32 {
    let name = executable.lastPathComponent
    let pid = try spawn(
        executable,
        arguments: arguments,
        standardInput: standardInput,
        standardOutput: standardOutput,
        standardError: standardError
    )
    onSpawn(pid)

    let timedOut = LockedFlag()
    let watchdog = Task {
        guard let timeout else { return }
        // A suspending clock stops while the Mac sleeps. With a closed lid, a limit
        // that kept counting would stop a tool that had barely had a chance to run.
        try await Task.sleep(for: timeout, clock: .suspending)
        timedOut.set()
        kill(-pid, SIGKILL)
    }
    defer { watchdog.cancel() }

    let status = await withTaskCancellationHandler {
        await waitForExit(of: pid)
    } onCancel: {
        kill(-pid, SIGKILL)
    }

    if timedOut.value { throw SubprocessError.timedOut(name) }
    try Task.checkCancellation()
    return status
}

/// Stops a tool left over from a previous run of the app, which a force-quit can
/// leave running. A stray Whisper alongside a new one risks running out of memory.
///
/// The path check matters because process IDs get reused: an old ID could by now
/// belong to something else entirely.
@discardableResult
public func stopOrphanedTool(pid: Int32, allowedTools: [URL]) -> Bool {
    guard pid > 0, let path = executablePath(of: pid),
          allowedTools.contains(where: { $0.resolvingSymlinksInPath().path == path }) else {
        return false
    }
    return kill(-pid, SIGKILL) == 0 || kill(pid, SIGKILL) == 0
}

func executablePath(of pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return URL(filePath: String(cString: buffer)).resolvingSymlinksInPath().path
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

private func spawn(
    _ executable: URL,
    arguments: [String],
    standardInput: URL?,
    standardOutput: URL,
    standardError: URL
) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, standardInput?.path ?? "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, standardOutput.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    posix_spawn_file_actions_addopen(&actions, 2, standardError.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Close everything else, so a tool can't inherit the database or other files.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attributes, 0)
    posix_spawnattr_set_qos_class_np(&attributes, QOS_CLASS_USER_INITIATED)

    let environment = ToolEnvironment.standard.map { "\($0.key)=\($0.value)" }
    let cArguments: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
    let cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
    defer {
        cArguments.forEach { free($0) }
        cEnvironment.forEach { free($0) }
    }

    var pid: pid_t = 0
    let result = posix_spawn(&pid, executable.path, &actions, &attributes, cArguments, cEnvironment)
    guard result == 0 else {
        throw SubprocessError.couldNotStart(executable.lastPathComponent, result)
    }
    return pid
}

/// Waits on a dedicated thread, so a long-running tool doesn't hold a pool thread.
private func waitForExit(of pid: pid_t) async -> Int32 {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            let signal = status & 0x7f
            continuation.resume(returning: signal == 0 ? (status >> 8) & 0xff : 128 + signal)
        }
    }
}
