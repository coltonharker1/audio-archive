import Foundation

/// The new RA numbers lined up in the Catalog and not yet applied. It lives only in
/// memory, and every function takes the shelf as it is now, which holds each tape's
/// real number. Applying them is `Pusher.renumber`.
public struct CatalogStaging: Equatable, Sendable {
    /// The numbers as they'll be after Apply, for the tapes that will change.
    public private(set) var staged: [Int64: String] = [:]
    /// The numbered reels, in the order the Catalog lists them.
    public private(set) var order: [Int64] = []

    public init() {}

    /// A staged change, as the Catalog lists it before it's applied.
    public struct Pending: Identifiable, Equatable, Sendable {
        public let tapeID: Int64
        public let title: String
        /// The number it has now, or nil for a tape that has none.
        public let current: String?
        public let proposed: String

        public var id: Int64 { tapeID }
    }

    /// What came of a number typed for a reel.
    public enum Typed: Equatable, Sendable {
        /// Nothing was typed, so the reel has its own number again.
        case restored
        case staged
        /// It isn't a catalog number, so nothing changed. This says why.
        case refused(String)
    }

    /// Forgets every staged change and lists the shelf's numbered reels by number.
    public mutating func reset(_ shelf: [ShelfTape]) {
        staged = [:]
        order = shelf
            .filter { $0.tape.catalogNumber != nil }
            .sorted { Self.rank($0.tape.catalogNumber) < Self.rank($1.tape.catalogNumber) }
            .map(\.id)
    }

    /// Keeps up with the shelf. With nothing staged the list is the shelf's. Otherwise
    /// a tape that's gone is dropped, along with its change, a numbered tape that's
    /// new takes its place in the list, and every other change is kept.
    public mutating func follow(_ shelf: [ShelfTape]) {
        let tapes = Self.byID(shelf)
        // A tape that now has the number staged for it has nothing left to change.
        staged = staged.filter { id, number in
            tapes[id].map { $0.tape.catalogNumber != number } ?? false
        }
        guard !staged.isEmpty else {
            reset(shelf)
            return
        }
        var list = order.filter { tapes[$0] != nil && number(of: $0, in: tapes) != nil }
        for tape in shelf where tape.tape.catalogNumber != nil && !list.contains(tape.id) {
            let rank = Self.rank(number(of: tape.id, in: tapes))
            let place = list.firstIndex { Self.rank(number(of: $0, in: tapes)) > rank }
            list.insert(tape.id, at: place ?? list.endIndex)
        }
        order = list
    }

    /// Moving a reel keeps the same set of numbers and deals them out in the new order,
    /// so the reels between where it was and where it went each shift by one.
    public mutating func move(from source: IndexSet, to destination: Int, in shelf: [ShelfTape]) {
        let moved = source.filter(order.indices.contains).map { order[$0] }
        let before = order.indices.contains(destination) ? order[destination] : nil
        move(moved, before: before, in: shelf)
    }

    /// The same move by tape: those reels go just ahead of `before`, or to the end
    /// with nil. A tape the list no longer has is skipped, so a drag held by tape
    /// still moves the reels that were dragged after the list changed under it.
    public mutating func move(_ ids: [Int64], before: Int64?, in shelf: [ShelfTape]) {
        let tapes = Self.byID(shelf)
        let moved = order.filter(ids.contains)
        guard !moved.isEmpty else { return }
        let numbers = order.compactMap { number(of: $0, in: tapes) }
            .sorted { (CatalogNumber.parse($0) ?? 0) < (CatalogNumber.parse($1) ?? 0) }
        // The first reel from the drop point on that isn't itself being moved.
        let anchor = before.flatMap(order.firstIndex(of:)).flatMap { start in
            order[start...].first { !moved.contains($0) }
        }
        var rest = order.filter { !moved.contains($0) }
        rest.insert(contentsOf: moved, at: anchor.flatMap(rest.firstIndex(of:)) ?? rest.endIndex)
        order = rest
        for (id, number) in zip(order, numbers) { stage(id, number, in: tapes) }
    }

    /// Stages a typed number for that one reel and sorts the list again. No other reel
    /// changes, even one that has the number: Apply refuses it then. Blank text puts
    /// the reel's own number back.
    public mutating func commitTyping(_ text: String, for tapeID: Int64, in shelf: [ShelfTape]) -> Typed {
        let tapes = Self.byID(shelf)
        guard let tape = tapes[tapeID] else { return .restored }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            staged[tapeID] = nil
            // A tape with no number of its own goes back among those without one.
            if tape.tape.catalogNumber == nil { order.removeAll { $0 == tapeID } }
            sort(tapes)
            return .restored
        }
        guard let newNumber = CatalogNumber.normalized(text) else {
            return .refused(CatalogError.invalid(text).localizedDescription)
        }
        stage(tapeID, newNumber, in: tapes)
        if !order.contains(tapeID) { order.append(tapeID) }
        sort(tapes)
        return .staged
    }

    /// Lists the reels by the numbers they'll have after Apply.
    private mutating func sort(_ tapes: [Int64: ShelfTape]) {
        order = order.sorted { Self.rank(number(of: $0, in: tapes)) < Self.rank(number(of: $1, in: tapes)) }
    }

    /// The number a reel will have after Apply.
    public func number(of tape: ShelfTape) -> String? {
        staged[tape.id] ?? tape.tape.catalogNumber
    }

    /// The tapes with no number, and none lined up for them.
    public func unnumbered(in shelf: [ShelfTape]) -> [ShelfTape] {
        shelf.filter { $0.tape.catalogNumber == nil && !order.contains($0.id) }
    }

    /// The staged changes, by the number each reel has now.
    public func pending(in shelf: [ShelfTape]) -> [Pending] {
        shelf.compactMap { tape -> Pending? in
            guard let number = staged[tape.id], number != tape.tape.catalogNumber else { return nil }
            return Pending(tapeID: tape.id, title: tape.tape.title, current: tape.tape.catalogNumber, proposed: number)
        }
        .sorted { (Self.rank($0.current), $0.tapeID) < (Self.rank($1.current), $1.tapeID) }
    }

    /// What Apply sends.
    public func changes(in shelf: [ShelfTape]) -> [Renumbering] {
        pending(in: shelf).map { Renumbering(tapeID: $0.tapeID, catalogNumber: $0.proposed) }
    }

    private mutating func stage(_ id: Int64, _ number: String, in tapes: [Int64: ShelfTape]) {
        staged[id] = tapes[id]?.tape.catalogNumber == number ? nil : number
    }

    private func number(of id: Int64, in tapes: [Int64: ShelfTape]) -> String? {
        staged[id] ?? tapes[id]?.tape.catalogNumber
    }

    private static func byID(_ shelf: [ShelfTape]) -> [Int64: ShelfTape] {
        Dictionary(uniqueKeysWithValues: shelf.map { ($0.id, $0) })
    }

    /// Where a number sorts. Anything that isn't one goes last.
    private static func rank(_ number: String?) -> Int {
        number.flatMap(CatalogNumber.parse) ?? .max
    }
}

extension [CatalogStaging.Pending] {
    /// Whether this is two reels trading the numbers they have now.
    public var isSwap: Bool {
        count == 2 && self[0].proposed == self[1].current && self[1].proposed == self[0].current
    }

    /// What the changes amount to, or nil with none.
    public var heading: String? {
        if isEmpty { return nil }
        if isSwap { return "Swap two numbers" }
        return count == 1 ? "Renumber 1 reel" : "Renumber \(count) reels"
    }

    /// What to know before applying them.
    public var explanation: String {
        isSwap
            ? "Apply both changes together. Old site addresses redirect to the new numbers. Update the labels on both boxes afterward."
            : "Relabel the boxes to match."
    }

    public var footerNote: String? {
        if isEmpty { return nil }
        let proposed = count == 1 ? "1 proposed change" : "\(count) proposed changes"
        return "\(proposed) · Awaiting confirmation"
    }
}
