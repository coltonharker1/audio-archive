import Darwin
import Foundation
import Testing
@testable import RemanenceCore

@Suite struct SubprocessTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "remanence-sub-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func script(_ body: String) throws -> URL {
        let url = directory.appending(path: "tool-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func run(
        _ tool: URL,
        timeout: Duration? = .seconds(20),
        input: URL? = nil,
        onSpawn: @Sendable (Int32) -> Void = { _ in }
    ) async throws -> (status: Int32, output: String, errors: String) {
        let out = directory.appending(path: "out-\(UUID().uuidString)")
        let err = directory.appending(path: "err-\(UUID().uuidString)")
        let status = try await runSubprocess(
            tool, arguments: [], standardInput: input, standardOutput: out, standardError: err,
            timeout: timeout, onSpawn: onSpawn
        )
        return (status, (try? String(contentsOf: out, encoding: .utf8)) ?? "", (try? String(contentsOf: err, encoding: .utf8)) ?? "")
    }

    private func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private func waitUntilGone(_ pid: Int32) async throws -> Bool {
        for _ in 0..<100 {
            if !isAlive(pid) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func capturesOutputAndStatus() async throws {
        let result = try await run(try script("echo hello; echo oops >&2; exit 4"))
        #expect(result.status == 4)
        #expect(result.output == "hello\n")
        #expect(result.errors == "oops\n")
    }

    @Test func readsInputFromAFile() async throws {
        let input = directory.appending(path: "in.txt")
        try "from a file".write(to: input, atomically: true, encoding: .utf8)
        #expect(try await run(try script("cat"), input: input).output == "from a file")
    }

    @Test func missingToolThrows() async {
        await #expect(throws: SubprocessError.self) {
            _ = try await run(directory.appending(path: "nope"))
        }
    }

    @Test func aHungToolTimesOut() async throws {
        await #expect(throws: SubprocessError.timedOut("hang.sh")) {
            let tool = directory.appending(path: "hang.sh")
            try "#!/bin/sh\nexec sleep 60\n".write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            _ = try await run(tool, timeout: .milliseconds(200))
        }
    }

    /// Output goes to files, so a child that outlives its parent while holding
    /// stdout can't hang the run. This is the bug that took down an overnight batch.
    @Test func aLeakedChildHoldingOutputDoesNotHang() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await run(try script("sleep 30 &\necho done"))
        #expect(result.status == 0)
        #expect(result.output == "done\n")
        #expect(clock.now - started < .seconds(5))
    }

    @Test func cancellingStopsTheToolAndItsChildren() async throws {
        let pidFile = directory.appending(path: "child.pid")
        let tool = try script("sleep 60 &\necho $! > \(pidFile.path)\nwait")
        let tasks = Task { try await run(tool) }

        var childPID: Int32?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = pid
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let child = try #require(childPID)
        #expect(isAlive(child))

        tasks.cancel()
        await #expect(throws: CancellationError.self) { _ = try await tasks.value }
        #expect(try await waitUntilGone(child))
    }

    @Test func toolsGetTheStandardEnvironmentOnly() async throws {
        setenv("REMANENCE_TEST_LEAK", "1", 1)
        let result = try await run(try script(#"echo "$USER|$HOME|$REMANENCE_TEST_LEAK""#))
        #expect(result.output == "\(NSUserName())|\(FileManager.default.homeDirectoryForCurrentUser.path)|\n")
    }

    @Test func spawnedToolsRunAtUserInitiatedPriority() async throws {
        // A tool can't easily report its own QoS, but Whisper's slowdown came from
        // the background band, which also lowers this scheduling value.
        let result = try await run(try script("ps -o nice= -p $$"))
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }

    @Test func anOrphanedToolIsStoppedOnlyIfItIsAKnownTool() async throws {
        let sleepTool = URL(filePath: "/bin/sleep")
        let out = directory.appending(path: "o")
        let err = directory.appending(path: "e")
        let recorded = Locked<Int32>(0)

        let running = Task {
            try await runSubprocess(
                sleepTool, arguments: ["60"], standardOutput: out, standardError: err,
                timeout: .seconds(30), onSpawn: { pid in recorded.mutate { $0 = pid } }
            )
        }
        defer { running.cancel() }
        while recorded.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let pid = recorded.value

        #expect(!stopOrphanedTool(pid: pid, allowedTools: [URL(filePath: "/opt/homebrew/bin/ffmpeg")]))
        #expect(isAlive(pid))

        #expect(stopOrphanedTool(pid: pid, allowedTools: [sleepTool]))
        #expect(try await waitUntilGone(pid))
    }

    @Test func aMissingProcessIsLeftAlone() {
        #expect(!stopOrphanedTool(pid: 999_999, allowedTools: [URL(filePath: "/bin/sleep")]))
    }
}
