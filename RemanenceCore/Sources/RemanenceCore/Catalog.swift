import Foundation
import GRDB

/// RA numbers: given to a tape when it's recorded or added, so the label on its box
/// is right from the start, and kept by the site when it's pushed.
public enum CatalogNumber {
    /// `12` becomes `RA-012`.
    public static func format(_ number: Int) -> String {
        "RA-" + String(format: "%03d", number)
    }

    /// `RA-012` becomes `12`. Anything else isn't a catalog number.
    public static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        let digits = trimmed.hasPrefix("RA-") ? String(trimmed.dropFirst(3)) : trimmed
        guard (1...6).contains(digits.count), digits.allSatisfy(\.isNumber), let value = Int(digits), value > 0 else { return nil }
        return value
    }

    /// Tidies what was typed: `12`, `ra-12` and `RA-012` are all `RA-012`.
    public static func normalized(_ text: String) -> String? {
        parse(text).map(format)
    }
}

public enum CatalogError: LocalizedError, Equatable {
    case invalid(String)
    case duplicate(String)
    case taken(String, by: String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let text): "“\(text)” isn’t a catalog number. They look like RA-012."
        case .duplicate(let number): "Two tapes can’t both be \(number)."
        case .taken(let number, let title): "\(number) already belongs to “\(title)”."
        }
    }
}

/// A new number for a tape.
public struct Renumbering: Equatable, Sendable {
    public let tapeID: Int64
    public let catalogNumber: String

    public init(tapeID: Int64, catalogNumber: String) {
        self.tapeID = tapeID
        self.catalogNumber = catalogNumber
    }
}

extension Library {
    /// The lowest number no tape here has, and that the site isn't known to be using.
    /// A number freed by deleting a tape that never reached the site is used again.
    static func nextCatalogNumber(_ db: Database, excluding taken: Set<String> = []) throws -> String {
        let used = Set(try String.fetchAll(db, sql: "SELECT catalog_number FROM tape WHERE catalog_number IS NOT NULL"))
            .union(taken)
            .compactMap(CatalogNumber.parse)
        let numbers = Set(used)
        var candidate = 1
        while numbers.contains(candidate) { candidate += 1 }
        return CatalogNumber.format(candidate)
    }

    /// The number the next new tape will get.
    public func nextCatalogNumber(excluding taken: Set<String> = []) async throws -> String {
        try await database.writer.read { db in try Self.nextCatalogNumber(db, excluding: taken) }
    }

    /// Checks a set of new numbers against each other and against every other tape.
    static func checkRenumbering(_ db: Database, _ changes: [Renumbering]) throws {
        for change in changes where CatalogNumber.parse(change.catalogNumber).map(CatalogNumber.format) != change.catalogNumber {
            throw CatalogError.invalid(change.catalogNumber)
        }
        var seen: Set<String> = []
        for change in changes where !seen.insert(change.catalogNumber).inserted {
            throw CatalogError.duplicate(change.catalogNumber)
        }
        let moving = Set(changes.map(\.tapeID))
        let others = try Row.fetchAll(db, sql: "SELECT id, title, catalog_number FROM tape WHERE catalog_number IS NOT NULL")
        for row in others where !moving.contains(row["id"] as Int64) {
            let number: String = row["catalog_number"]
            if seen.contains(number) { throw CatalogError.taken(number, by: row["title"]) }
        }
    }

    /// Gives tapes new numbers here. Tapes on the site are renumbered there first; see
    /// `Pusher.renumber`.
    func applyRenumbering(_ changes: [Renumbering], siteClocks: [Int64: String] = [:]) async throws {
        try await database.writer.write { db in
            try Self.checkRenumbering(db, changes)
            // Numbers are unique, so each tape steps aside first and a swap never meets
            // itself halfway.
            for change in changes {
                try db.execute(sql: "UPDATE tape SET catalog_number = NULL WHERE id = ?", arguments: [change.tapeID])
            }
            for change in changes {
                if let clock = siteClocks[change.tapeID] {
                    try db.execute(sql: "UPDATE tape SET catalog_number = ?, site_updated_at = ? WHERE id = ?",
                                   arguments: [change.catalogNumber, clock, change.tapeID])
                } else {
                    try db.execute(sql: "UPDATE tape SET catalog_number = ? WHERE id = ?",
                                   arguments: [change.catalogNumber, change.tapeID])
                }
            }
        }
    }
}

/// One post's move on the site.
public struct SiteRenumber: Encodable, Equatable, Sendable {
    public let tapeUuid: String
    public let catalogNumber: String
    public let newCatalogNumber: String
    public let expectedUpdatedAt: String
}

extension Pusher {
    /// Gives tapes new numbers, on the site and here. Posts on the site move all at
    /// once, so two can swap; if the site refuses, nothing here changes. A published
    /// post's old address keeps working, sent on to the new one.
    public func renumber(_ changes: [Renumbering]) async throws {
        let changes = changes.filter { !$0.catalogNumber.isEmpty }
        guard !changes.isEmpty else { return }
        let tapes = try await library.database.writer.read { db -> [Int64: Tape] in
            try Library.checkRenumbering(db, changes)
            let rows = try Tape.filter(keys: changes.map(\.tapeID)).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { tape in tape.id.map { ($0, tape) } })
        }
        let moves = changes.filter { tapes[$0.tapeID]?.catalogNumber != $0.catalogNumber }
        guard !moves.isEmpty else { return }

        var clocks: [Int64: String] = [:]
        let onSite = moves.compactMap { change -> (Int64, SiteRenumber)? in
            guard let tape = tapes[change.tapeID], tape.pushedAt != nil,
                  let current = tape.catalogNumber, let clock = tape.siteUpdatedAt else { return nil }
            return (change.tapeID, SiteRenumber(tapeUuid: tape.uuid.lowercased(), catalogNumber: current,
                                               newCatalogNumber: change.catalogNumber, expectedUpdatedAt: clock))
        }
        if !onSite.isEmpty {
            let states = try await site.renumber(onSite.map(\.1))
            let byUUID = Dictionary(states.compactMap { state in state.tapeUuid.map { ($0.lowercased(), state) } },
                                    uniquingKeysWith: { first, _ in first })
            for (tapeID, move) in onSite {
                if let state = byUUID[move.tapeUuid] { clocks[tapeID] = state.updatedAt }
            }
        }
        try await library.applyRenumbering(moves, siteClocks: clocks)
    }
}
