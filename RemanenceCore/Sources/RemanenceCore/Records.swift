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
    public var whereFound: String?
    public var dateFound: String?
    /// The site's own clock for the post, from the last time the app read or wrote it.
    public var siteUpdatedAt: String?
    /// What the site had then, as JSON. See `SiteSnapshot`.
    public var siteSnapshot: String?
    public var context: String?
    public var machineId: Int64?
    public var speed: String?
    public var titleIsProvisional: Bool = false
    public var approvedAt: Date?
    public var pushedAt: Date?
    public var createdAt: Date
    /// The collection it came in, and its place there.
    public var collectionId: Int64?
    public var collectionPosition: Double?

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
    public var side: String?
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
    /// Written by hand for the site. `summary` is Claude's, kept as reference.
    public var description: String?
    /// See `TrackAdjustments`.
    public var gainDb: Double = 0
    public var speed: Double = 1
    public var reversed: Bool = false
    /// The track this one plays straight after, as one track on the site.
    public var appendedToTrackId: Int64?
    /// Its place on the site, once tracks have been reordered.
    public var sortIndex: Double?
    /// Master seconds left out at the start and end of the track's stretch, in
    /// recording order, so they stay with the same audio when it's reversed.
    public var cutStart: Double = 0
    public var cutEnd: Double = 0

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A photo of a tape, its box or anything that came with it.
public struct TapeImage: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "tape_image"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var tapeId: Int64
    public var position: Int
    public var path: String
    public var sha256: String
    public var filename: String
    public var caption: String?
    /// Where the site serves this photo, once it's there.
    public var siteUrl: String?

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
