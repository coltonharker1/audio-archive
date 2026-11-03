import Foundation
import GRDB

public struct Tape: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var uuid: String
    public var catalogNumber: String?
    public var title: String
    public var medium: String?
    public var era: String?
    public var description: String?
    public var context: String?
    public var titleIsProvisional: Bool = false
    public var approvedAt: Date?
    public var pushedAt: Date?
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One continuous recording. Paths are relative to the library, so the library
/// folder can move.
public struct Source: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var tapeId: Int64
    public var position: Int
    public var masterPath: String
    public var sha256: String?
    public var prepPath: String?
    public var peaksPath: String?
    public var duration: Double
    public var sampleRate: Int?
    public var channels: Int?
    public var bitDepth: Int?
    public var transcriptModel: String?
    public var trimStart: Double = 0
    public var trimEnd: Double?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Track: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var sourceId: Int64
    public var startMarkerId: Int64?
    public var name: String?
    public var recordingType: String?
    public var summaryShort: String?
    public var summary: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// What the pipeline is doing with a tape right now.
public enum TapeStatus: Hashable, Sendable {
    case idle
    case waiting
    case working(type: JobType, jobID: Int64)
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .waiting, .working: true
        case .idle, .failed: false
        }
    }
}

/// A tape with what the shelf needs to show and play it.
public struct ShelfTape: Identifiable, Hashable, Sendable {
    public struct Item: Identifiable, Hashable, Sendable {
        public let source: Source
        public let name: String

        public var id: Int64 { source.id ?? 0 }
    }

    public let tape: Tape
    public let items: [Item]
    public var status: TapeStatus = .idle
    public var markerCount: Int = 0

    /// One track per source, plus one for each marker.
    public var trackCount: Int { items.count + markerCount }
    public var id: Int64 { tape.id ?? 0 }
    public var duration: Double { items.reduce(0) { $0 + $1.source.duration } }
}

/// The physical format, which sets how a tape looks on the shelf.
public enum TapeFormat: Sendable {
    case sevenInchReel, fiveInchReel, cassette, microcassette, unknown

    public init(medium: String?) {
        let medium = (medium ?? "").lowercased()
        if medium.contains("micro") {
            self = .microcassette
        } else if medium.contains("cassette") {
            self = .cassette
        } else if medium.contains("7\"") {
            self = .sevenInchReel
        } else if medium.contains("5\"") {
            self = .fiveInchReel
        } else {
            self = .unknown
        }
    }
}
