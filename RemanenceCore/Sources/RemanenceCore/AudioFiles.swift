import CryptoKit
import Foundation

public enum KnownTools {
    public static let ffmpeg = URL(filePath: "/opt/homebrew/bin/ffmpeg")
    public static let ffprobe = URL(filePath: "/opt/homebrew/bin/ffprobe")
    public static let whisper = URL(filePath: "/opt/homebrew/bin/whisper-cli")
    public static var claude: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude")
    }
}

/// SHA-256 of a file, read in pieces so large masters don't load into memory.
func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
        let finished: Bool = try autoreleasepool {
            guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { return true }
            hasher.update(data: chunk)
            return false
        }
        if finished { break }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// SHA-256 of some bytes, as hex.
func sha256(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct AudioDetails: Equatable, Sendable {
    let duration: Double
    let sampleRate: Int?
    let channels: Int?
    let bitDepth: Int?
}

enum ProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let file): "Couldn’t read the audio details of \(file)."
        }
    }
}

func probeAudio(_ url: URL, ffprobe: URL = KnownTools.ffprobe) async throws -> AudioDetails {
    struct Output: Decodable {
        struct Stream: Decodable {
            let sample_rate: String?
            let channels: Int?
            let bits_per_sample: Int?
            let bits_per_raw_sample: String?
        }
        struct Format: Decodable {
            let duration: String?
        }
        let streams: [Stream]
        let format: Format
    }

    let (status, data) = try await runToolCapturingOutput(
        ffprobe,
        arguments: [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=sample_rate,channels,bits_per_sample,bits_per_raw_sample:format=duration",
            "-of", "json", url.path,
        ],
        timeout: .seconds(60)
    )
    guard status == 0,
          let output = try? JSONDecoder().decode(Output.self, from: data),
          let stream = output.streams.first,
          let duration = output.format.duration.flatMap(Double.init) else {
        throw ProbeError.failed(url.lastPathComponent)
    }

    let rawBits = stream.bits_per_raw_sample.flatMap(Int.init)
    let bits = stream.bits_per_sample.flatMap { $0 > 0 ? $0 : nil } ?? rawBits
    return AudioDetails(
        duration: duration,
        sampleRate: stream.sample_rate.flatMap(Int.init),
        channels: stream.channels,
        bitDepth: bits
    )
}
