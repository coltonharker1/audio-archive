import Foundation

/// Writes a 24-bit CAF file that's valid at every moment.
///
/// CAF allows the audio chunk to declare an unknown size, meaning "until the end of
/// the file", so a crash or power cut still leaves a playable recording missing only
/// its last moments. It has no 4 GB limit either, which a long 96 kHz transfer would
/// hit in WAV. The header is corrected on a normal close.
public final class CaptureFile {
    public let url: URL
    public let sampleRate: Double
    public let channels: Int

    public private(set) var framesWritten: Int64 = 0

    private let handle: FileHandle
    private var sizeOffset: UInt64 = 0
    private var lastSync = Date()
    private var isClosed = false

    static let bytesPerSample = 3

    public init(url: URL, sampleRate: Double, channels: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)

        let header = Self.header(sampleRate: sampleRate, channels: channels)
        sizeOffset = UInt64(header.sizeOffset)
        try handle.write(contentsOf: header.data)
        try handle.synchronize()
    }

    static func header(sampleRate: Double, channels: Int) -> (data: Data, sizeOffset: Int) {
        func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
            withUnsafeBytes(of: value.bigEndian) { Data($0) }
        }
        var data = Data("caff".utf8)
        data += bigEndian(UInt16(1)) + bigEndian(UInt16(0))

        data += Data("desc".utf8) + bigEndian(Int64(32))
        data += bigEndian(sampleRate.bitPattern)
        data += Data("lpcm".utf8)
        data += bigEndian(UInt32(2)) // Little-endian integer samples.
        data += bigEndian(UInt32(bytesPerSample * channels))
        data += bigEndian(UInt32(1))
        data += bigEndian(UInt32(channels))
        data += bigEndian(UInt32(bytesPerSample * 8))

        data += Data("data".utf8)
        let sizeOffset = data.count
        data += bigEndian(Int64(-1)) // Unknown: the audio runs to the end of the file.
        data += bigEndian(UInt32(0)) // Edit count.
        return (data, sizeOffset)
    }

    /// Appends interleaved 24-bit samples, syncing to disk every couple of seconds
    /// so very little can be lost if the power goes.
    public func append(_ samples: Data, frames: Int) throws {
        try handle.write(contentsOf: samples)
        framesWritten += Int64(frames)
        if Date().timeIntervalSince(lastSync) >= 2 {
            try handle.synchronize()
            lastSync = Date()
        }
    }

    /// Writes the true audio size. A file that never gets here is still valid.
    public func close() throws {
        guard !isClosed else { return }
        isClosed = true
        defer { try? handle.close() }
        let bytes = 4 + framesWritten * Int64(Self.bytesPerSample * channels)
        try handle.synchronize()
        try handle.seek(toOffset: sizeOffset)
        try handle.write(contentsOf: withUnsafeBytes(of: bytes.bigEndian) { Data($0) })
        try handle.synchronize()
    }

    /// Converts non-interleaved float channels to interleaved 24-bit samples.
    public static func interleave(
        _ channels: [UnsafePointer<Float>],
        frames: Int
    ) -> Data {
        var output = Data(count: frames * channels.count * bytesPerSample)
        output.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var index = 0
            for frame in 0..<frames {
                for channel in channels {
                    let value = Int32(max(-1, min(1, channel[frame])) * 8_388_607)
                    bytes[index] = UInt8(truncatingIfNeeded: value)
                    bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
                    bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
                    index += bytesPerSample
                }
            }
        }
        return output
    }
}
