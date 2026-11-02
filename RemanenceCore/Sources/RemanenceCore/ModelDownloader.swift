import Foundation

public enum ModelDownloadError: LocalizedError {
    case badResponse(Int)
    case tooSmall(Int64)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code): "The server responded with status \(code)."
        case .tooSmall: "The download was incomplete."
        }
    }
}

/// Downloads a model to its final path only once it has arrived in full, so an
/// interrupted download can't be mistaken for a working model.
public enum ModelDownloader {
    public static func download(
        from source: URL,
        to destination: URL,
        minimumBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // URLSession's async download(from:delegate:) never reports progress,
        // so this drives a download task through a session delegate instead.
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: source)
        let temporary = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let size = attributes[.size] as? Int64 ?? 0
        guard size >= minimumBytes else { throw ModelDownloadError.tooSmall(size) }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var kept: Result<URL, Error>?
    private var stored: CheckedContinuation<URL, Error>?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    var continuation: CheckedContinuation<URL, Error>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// URLSession deletes its file when this returns, so it's moved here.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let outcome: Result<URL, Error>
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            outcome = .failure(ModelDownloadError.badResponse(http.statusCode))
        } else {
            let kept = FileManager.default.temporaryDirectory
                .appending(path: "remanence-download-\(UUID().uuidString)")
            outcome = Result { try FileManager.default.moveItem(at: location, to: kept); return kept }
        }
        lock.withLock { kept = outcome }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, outcome): (CheckedContinuation<URL, Error>?, Result<URL, Error>?) = lock.withLock {
            defer { stored = nil }
            return (stored, kept)
        }
        if let error {
            if case .success(let url) = outcome { try? FileManager.default.removeItem(at: url) }
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(with: outcome ?? .failure(URLError(.unknown)))
        }
    }
}
