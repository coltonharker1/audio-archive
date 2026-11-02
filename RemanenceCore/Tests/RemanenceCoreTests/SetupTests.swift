import Foundation
import Testing
@testable import RemanenceCore

private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0.0

    var value: Double { lock.withLock { stored } }
    func set(_ newValue: Double) { lock.withLock { stored = newValue } }
}

@Suite struct SetupTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "remanence-setup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func script(_ name: String, _ body: String, executable: Bool = true) throws -> URL {
        let url = directory.appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }

    private func tool(at path: URL) -> Requirement {
        Requirement(
            id: "tool", name: "Tool", purpose: "", path: path, isOptional: false,
            kind: .tool(arguments: [], installCommand: "")
        )
    }

    private func model(at path: URL, minimum: Int64) -> Requirement {
        Requirement(
            id: "model", name: "Model", purpose: "", path: path, isOptional: false,
            kind: .model(source: URL(string: "https://example.com/m")!, minimumBytes: minimum)
        )
    }

    @Test func aWorkingToolIsReady() async throws {
        #expect(await SetupCatalog.check(tool(at: try script("ok", "exit 0"))) == .ready)
    }

    @Test func anAbsentToolIsMissing() async {
        #expect(await SetupCatalog.check(tool(at: directory.appending(path: "nope"))) == .missing)
    }

    @Test func aFailingToolReportsItsStatus() async throws {
        #expect(await SetupCatalog.check(tool(at: try script("bad", "exit 3"))) == .failed("Exited with status 3"))
    }

    @Test func aNonExecutableFileFails() async throws {
        let path = try script("plain", "exit 0", executable: false)
        #expect(await SetupCatalog.check(tool(at: path)) == .failed("Not executable"))
    }

    /// Tools must pass here the way they will in the app, which doesn't get the
    /// shell's environment, so nothing from this process may leak through.
    @Test func toolsDoNotInheritTheEnvironment() async throws {
        setenv("REMANENCE_TEST_INHERITED", "1", 1)
        let path = try script("env", #"[ -z "$REMANENCE_TEST_INHERITED" ] && [ -n "$HOME" ]"#)
        #expect(await SetupCatalog.check(tool(at: path)) == .ready)
    }

    @Test func aHungToolTimesOut() async throws {
        let path = try script("hang", "exec sleep 30")
        await #expect(throws: ToolError.self) {
            _ = try await runTool(path, arguments: [], timeout: .milliseconds(200))
        }
    }

    @Test func modelSizeDecidesItsState() async throws {
        let path = directory.appending(path: "model.bin")
        #expect(await SetupCatalog.check(model(at: path, minimum: 10)) == .missing)

        try Data(count: 5).write(to: path)
        #expect(await SetupCatalog.check(model(at: path, minimum: 10)) == .incomplete)

        try Data(count: 10).write(to: path)
        #expect(await SetupCatalog.check(model(at: path, minimum: 10)) == .ready)
    }

    @Test func aDownloadArrivesAtItsDestination() async throws {
        let source = directory.appending(path: "source.bin")
        try Data(count: 2048).write(to: source)
        let destination = directory.appending(path: "nested/final.bin")

        try await ModelDownloader.download(from: source, to: destination, minimumBytes: 2048) { _ in }

        let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64
        #expect(size == 2048)
    }

    @Test func aShortDownloadLeavesNoModelBehind() async throws {
        let source = directory.appending(path: "short.bin")
        try Data(count: 10).write(to: source)
        let destination = directory.appending(path: "final.bin")

        await #expect(throws: ModelDownloadError.self) {
            try await ModelDownloader.download(from: source, to: destination, minimumBytes: 2048) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// Reaches the network, so it only runs with REMANENCE_NETWORK_TESTS=1.
    /// Uses the smallest real model, and covers HTTPS redirects and progress.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REMANENCE_NETWORK_TESTS"] == "1"))
    func aRealModelDownloads() async throws {
        let paths = LibraryPaths(library: directory, support: directory)
        let requirement = try #require(SetupCatalog.requirements(paths: paths).first { $0.id == "model-vad" })
        guard case .model(let source, let minimumBytes) = requirement.kind else {
            Issue.record("Expected a model")
            return
        }

        let reported = Reported()
        try await ModelDownloader.download(from: source, to: requirement.path, minimumBytes: minimumBytes) { value in
            reported.set(value)
        }

        #expect(await SetupCatalog.check(requirement) == .ready)
        #expect(reported.value > 0)
    }

    @Test func everyRequiredItemIsInTheCatalog() {
        let paths = LibraryPaths(library: directory, support: directory)
        let requirements = SetupCatalog.requirements(paths: paths)
        let required = Set(requirements.filter { !$0.isOptional }.map(\.id))
        #expect(required == ["ffmpeg", "ffprobe", "whisper-cli", "claude", "claude-login", "model-base", "model-vad"])
        #expect(requirements.first { $0.id == "model-medium" }?.isOptional == true)
    }
}
