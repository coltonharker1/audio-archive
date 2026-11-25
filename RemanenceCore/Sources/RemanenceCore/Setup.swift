import Foundation

/// Something the app needs on this Mac before it can process audio.
public struct Requirement: Identifiable, Sendable {
    public enum Kind: Sendable {
        /// A command-line tool, checked by running it with these arguments.
        case tool(arguments: [String], installCommand: String)
        /// A model file. Anything smaller than the minimum is a partial download.
        case model(source: URL, minimumBytes: Int64)
    }

    public let id: String
    public let name: String
    public let purpose: String
    public let path: URL
    public let isOptional: Bool
    public let kind: Kind
    /// Shown instead of the exit status when a tool runs but reports a problem.
    public var failureMessage: String?
}

/// What every tool runs with. A GUI app doesn't get the shell's environment, and
/// Claude Code reports "Not logged in" without USER, so this is set explicitly.
public enum ToolEnvironment {
    public static var standard: [String: String] {
        [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(),
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]
    }
}

public enum RequirementState: Equatable, Sendable {
    case ready
    case missing
    case incomplete
    case failed(String)
}

public enum SetupCatalog {
    public static func requirements(paths: LibraryPaths) -> [Requirement] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let homebrew = URL(filePath: "/opt/homebrew/bin")
        let huggingFace = "https://huggingface.co"

        return [
            Requirement(
                id: "ffmpeg",
                name: "FFmpeg",
                purpose: "Prepares audio for transcription",
                path: homebrew.appending(path: "ffmpeg"),
                isOptional: false,
                kind: .tool(arguments: ["-version"], installCommand: "brew install ffmpeg")
            ),
            Requirement(
                id: "ffprobe",
                name: "FFprobe",
                purpose: "Reads audio file details",
                path: homebrew.appending(path: "ffprobe"),
                isOptional: false,
                kind: .tool(arguments: ["-version"], installCommand: "brew install ffmpeg")
            ),
            Requirement(
                id: "whisper-cli",
                name: "Whisper",
                purpose: "Transcribes speech",
                path: homebrew.appending(path: "whisper-cli"),
                isOptional: false,
                kind: .tool(arguments: ["--help"], installCommand: "brew install whisper-cpp")
            ),
            Requirement(
                id: "claude",
                name: "Claude Code",
                purpose: "Writes summaries",
                path: home.appending(path: ".local/bin/claude"),
                isOptional: false,
                kind: .tool(
                    arguments: ["--version"],
                    installCommand: "curl -fsSL https://claude.ai/install.sh | bash"
                )
            ),
            Requirement(
                id: "claude-login",
                name: "Claude sign-in",
                purpose: "Lets Claude Code write summaries",
                path: home.appending(path: ".local/bin/claude"),
                isOptional: false,
                kind: .tool(arguments: ["auth", "status"], installCommand: "claude auth login"),
                failureMessage: "Not signed in. Run the command in Terminal."
            ),
            Requirement(
                id: "model-base",
                name: "Speech model (base)",
                purpose: "Everyday transcription",
                path: paths.models.appending(path: "ggml-base.en.bin"),
                isOptional: false,
                kind: .model(
                    source: URL(string: "\(huggingFace)/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!,
                    minimumBytes: 140_000_000
                )
            ),
            Requirement(
                id: "model-vad",
                name: "Voice detection model",
                purpose: "Stops Whisper inventing words over music and silence",
                path: paths.models.appending(path: "ggml-silero-v5.1.2.bin"),
                isOptional: false,
                kind: .model(
                    source: URL(string: "\(huggingFace)/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
                    minimumBytes: 800_000
                )
            ),
            Requirement(
                id: "model-medium",
                name: "Speech model (medium)",
                purpose: "Better transcripts for clear recordings",
                path: paths.models.appending(path: "ggml-medium.en.bin"),
                isOptional: true,
                kind: .model(
                    source: URL(string: "\(huggingFace)/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin")!,
                    minimumBytes: 1_400_000_000
                )
            ),
        ]
    }

    /// Checks one requirement. Tools are actually run, with almost no environment,
    /// because a GUI app doesn't inherit the shell's `PATH`.
    public static func check(_ requirement: Requirement) async -> RequirementState {
        switch requirement.kind {
        case .model(_, let minimumBytes):
            let attributes = try? FileManager.default.attributesOfItem(atPath: requirement.path.path)
            guard let size = attributes?[.size] as? Int64 else { return .missing }
            return size >= minimumBytes ? .ready : .incomplete

        case .tool(let arguments, _):
            guard FileManager.default.fileExists(atPath: requirement.path.path) else { return .missing }
            guard FileManager.default.isExecutableFile(atPath: requirement.path.path) else {
                return .failed("Not executable")
            }
            do {
                let status = try await runTool(requirement.path, arguments: arguments, timeout: .seconds(15))
                return status == 0 ? .ready : .failed(requirement.failureMessage ?? "Exited with status \(status)")
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }
}

public enum ToolError: LocalizedError {
    case timedOut

    public var errorDescription: String? { "Didn't respond in time" }
}

/// Runs a tool and returns its exit status and standard output. The output goes
/// through a file because a full pipe could otherwise hang the tool.
func runToolCapturingOutput(
    _ executable: URL,
    arguments: [String],
    timeout: Duration
) async throws -> (status: Int32, output: Data) {
    let file = FileManager.default.temporaryDirectory
        .appending(path: "remanence-tool-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: file) }

    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }

    let status = try await runTool(executable, arguments: arguments, timeout: timeout, standardOutput: handle)
    return (status, try Data(contentsOf: file))
}

/// Runs a tool and returns its exit status, discarding its output by default.
/// The cancel-safe runner for pipeline jobs comes in Phase 2.
func runTool(
    _ executable: URL,
    arguments: [String],
    timeout: Duration,
    standardOutput: FileHandle = .nullDevice
) async throws -> Int32 {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ToolEnvironment.standard
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = standardOutput
    process.standardError = FileHandle.nullDevice

    let exited = ExitSignal()
    process.terminationHandler = { _ in exited.fire() }
    try process.run()

    let timeoutTask = Task {
        try await Task.sleep(for: timeout)
        process.terminate()
    }
    defer { timeoutTask.cancel() }

    // Always wait for the real exit. Reading terminationReason or terminationStatus
    // of a running process raises an Objective-C exception and aborts the app, and
    // a cancelled task would otherwise stop waiting early. Cancelling stops the tool
    // instead, then waits for it to go.
    await withTaskCancellationHandler {
        await exited.wait()
    } onCancel: {
        process.terminate()
    }

    try Task.checkCancellation()
    if process.terminationReason == .uncaughtSignal, !timeoutTask.isCancelled {
        throw ToolError.timedOut
    }
    return process.terminationStatus
}

/// Fires once when a process exits. Unlike an AsyncStream, waiting on it doesn't
/// end early when the waiting task is cancelled.
private final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fire() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            hasFired = true
            defer { waiter = nil }
            return waiter
        }
        toResume?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyFired = lock.withLock {
                if !hasFired { waiter = continuation }
                return hasFired
            }
            if alreadyFired { continuation.resume() }
        }
    }
}
