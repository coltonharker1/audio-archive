import Accelerate
import AVFoundation
import Foundation
import GRDB

/// How a track should sound, set in edit mode. Masters are never changed: these are
/// heard in edit mode and applied to the copies made when a tape is pushed.
public struct TrackAdjustments: Codable, Hashable, Sendable {
    /// Loudness change in decibels.
    public var gainDB: Double
    /// Playback speed, changing pitch and tempo together like a tape machine. 0.5 plays
    /// a tape recorded at 3¾ ips that was captured at 7½ ips.
    public var speed: Double
    /// Plays the track backwards, for audio recorded in the other direction.
    public var reversed: Bool

    public static let gainRange: ClosedRange<Double> = -24...24
    public static let speedRange: ClosedRange<Double> = 0.25...4
    public static let none = TrackAdjustments()

    public init(gainDB: Double = 0, speed: Double = 1, reversed: Bool = false) {
        // Rounded, so the same settings always make the same files and hashes.
        self.gainDB = (min(Self.gainRange.upperBound, max(Self.gainRange.lowerBound, gainDB)) * 10).rounded() / 10
        self.speed = (min(Self.speedRange.upperBound, max(Self.speedRange.lowerBound, speed)) * 1000).rounded() / 1000
        self.reversed = reversed
    }

    public var isNeutral: Bool { gainDB == 0 && speed == 1 && !reversed }

    /// How long a stretch of the master lasts once played at this speed.
    public func duration(of masterSeconds: Double) -> Double { masterSeconds / speed }

    /// The ffmpeg filters for level and speed, or nil when neither changes.
    /// Speed is resampled back to the master's rate, so it stays a standard rate.
    func filters(sampleRate: Int) -> String? {
        var filters: [String] = []
        if gainDB != 0 { filters.append(String(format: "volume=%.1fdB", gainDB)) }
        if speed != 1 {
            let rate = Int((Double(sampleRate) * speed).rounded())
            filters.append("asetrate=\(rate)")
            filters.append("aresample=\(sampleRate)")
        }
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    /// Part of the name of a push's cached files, so changed settings make new ones.
    var fileTag: String {
        guard !isNeutral else { return "" }
        return String(format: "-g%.1f-s%.3f", gainDB, speed) + (reversed ? "-r" : "")
    }
}

public enum AdjustmentError: LocalizedError, Equatable {
    case alreadyOnSite

    public var errorDescription: String? {
        switch self {
        case .alreadyOnSite: "This tape is already on the site, and its audio there can’t be replaced yet."
        }
    }
}

extension Track {
    public var adjustments: TrackAdjustments {
        get { TrackAdjustments(gainDB: gainDb, speed: speed, reversed: reversed) }
        set {
            gainDb = newValue.gainDB
            speed = newValue.speed
            reversed = newValue.reversed
        }
    }
}

extension Library {
    /// Sets how a track sounds. A track that has no row yet gets one. Tapes already
    /// on the site are refused, since the site's audio wouldn't follow.
    public func setAdjustments(sourceID: Int64, startMarkerID: Int64?, _ adjustments: TrackAdjustments) async throws {
        try await database.writer.write { db in
            let pushed = try Date?.fetchOne(db, sql: """
                SELECT t.pushed_at FROM tape t JOIN source s ON s.tape_id = t.id WHERE s.id = ?
                """, arguments: [sourceID]) ?? nil
            guard pushed == nil else { throw AdjustmentError.alreadyOnSite }
            var track = try Track
                .filter(Column("source_id") == sourceID)
                .filter(startMarkerID == nil ? Column("start_marker_id") == nil : Column("start_marker_id") == startMarkerID)
                .fetchOne(db) ?? Track(sourceId: sourceID, startMarkerId: startMarkerID)
            track.adjustments = adjustments
            try track.save(db)
        }
    }
}

/// Writes a stretch of a master backwards to a new file in the master's own format.
/// The master is only read, a second at a time, so long tracks use little memory.
/// The same input always makes the same file.
func writeReversed(_ master: URL, from start: Double, to end: Double, into output: URL) throws {
    let input = try AVAudioFile(forReading: master, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = input.processingFormat
    let rate = format.sampleRate
    let first = AVAudioFramePosition(max(0, (start * rate).rounded()))
    let last = min(input.length, AVAudioFramePosition((end * rate).rounded()))
    guard last > first else { throw PushError.nothingToPush }

    try? FileManager.default.removeItem(at: output)
    // Whole-number samples at the master's depth, so nothing is lost. A compressed
    // master has no depth of its own and gets 24 bits.
    let source = input.fileFormat.settings
    let isFloat = source[AVLinearPCMIsFloatKey] as? Bool ?? false
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: format.channelCount,
        AVLinearPCMBitDepthKey: source[AVLinearPCMBitDepthKey] as? Int ?? 24,
        AVLinearPCMIsFloatKey: isFloat,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let writer = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

    let chunk = AVAudioFrameCount(rate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw PushError.nothingToPush }
    var position = last
    while position > first {
        let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), position - first))
        input.framePosition = position - AVAudioFramePosition(count)
        try input.read(into: buffer, frameCount: count)
        reverseInPlace(buffer)
        try writer.write(from: buffer)
        position -= AVAudioFramePosition(count)
    }
}

/// Reverses the frames of a buffer, every channel alike.
func reverseInPlace(_ buffer: AVAudioPCMBuffer) {
    guard let channels = buffer.floatChannelData else { return }
    let count = Int(buffer.frameLength)
    for channel in 0..<Int(buffer.format.channelCount) {
        var samples = UnsafeMutableBufferPointer(start: channels[channel], count: count)
        samples.reverse()
    }
}

extension Library {
    /// A tape's recordings, in order.
    public func sources(tapeID: Int64) async throws -> [Source] {
        try await database.writer.read { db in
            try Source.filter(Column("tape_id") == tapeID).order(Column("position")).fetchAll(db)
        }
    }
}

/// The loudest sample in a stretch of a recording, in decibels below full scale,
/// read a second at a time. Silence reads as -120.
public func measurePeak(of url: URL, from start: Double, to end: Double) throws -> Double {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let rate = file.processingFormat.sampleRate
    let first = AVAudioFramePosition(max(0, (start * rate).rounded()))
    let last = min(file.length, AVAudioFramePosition((end * rate).rounded()))
    let chunk = AVAudioFrameCount(rate)
    guard last > first, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
        return -120
    }
    file.framePosition = first
    var loudest: Float = 0
    var position = first
    while position < last {
        let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), last - position))
        try file.read(into: buffer, frameCount: count)
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
        for channel in 0..<Int(buffer.format.channelCount) {
            var peak: Float = 0
            vDSP_maxmgv(channels[channel], 1, &peak, vDSP_Length(buffer.frameLength))
            loudest = max(loudest, peak)
        }
        position += AVAudioFramePosition(buffer.frameLength)
    }
    return loudest > 0 ? max(-120, 20 * log10(Double(loudest))) : -120
}
