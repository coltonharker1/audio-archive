import Foundation

/// Where work last stopped on a tape, so it can be picked up again. It's kept with
/// the app's settings, never in the library.
public struct WorkPosition: Codable, Equatable, Sendable {
    /// Which of a tape's screens was showing.
    public enum Tab: String, Codable, Sendable {
        case review, edit, readAlong, post
    }

    public var tapeUUID: String
    public var tab: Tab
    /// The recording that was being worked on.
    public var sourceID: Int64
    /// The playhead, in seconds of that recording's master.
    public var playhead: Double
    /// The stretch of the recording Review had zoomed in on, if it's known.
    public var zoomStart: Double?
    public var zoomSpan: Double?
    /// The track Edit had selected, as `PostTrack.id` names it.
    public var editTrackID: String?

    /// The closest Review zooms in, in seconds.
    public static let minimumZoomSpan: Double = 4

    public init(
        tapeUUID: String,
        tab: Tab,
        sourceID: Int64,
        playhead: Double,
        zoomStart: Double? = nil,
        zoomSpan: Double? = nil,
        editTrackID: String? = nil
    ) {
        self.tapeUUID = tapeUUID
        self.tab = tab
        self.sourceID = sourceID
        self.playhead = playhead
        self.zoomStart = zoomStart
        self.zoomSpan = zoomSpan
        self.editTrackID = editTrackID
    }

    /// A saved position that still leads somewhere.
    public struct Resolved: Equatable, Sendable {
        public let tape: ShelfTape
        /// Which of the tape's recordings it's in.
        public let itemIndex: Int
        /// The position, adjusted to fit the tape as it is now.
        public let position: WorkPosition

        public var item: ShelfTape.Item { tape.items[itemIndex] }

        /// "Resume Side A", or plain "Resume" for a recording with no side name.
        public var buttonTitle: String {
            guard let side = item.source.side, !side.isEmpty else { return "Resume" }
            // A long name is cut, since the button is as wide as its words.
            let name = side.count > 16 ? side.prefix(15).trimmingCharacters(in: .whitespaces) + "…" : side
            return "Resume Side \(name)"
        }
    }

    /// Checks the position against the shelf. Nil when its tape is gone or has no
    /// recordings. A recording that's gone gives way to the tape's first, from the
    /// start, and times are kept within the recording.
    public func resolved(in shelf: [ShelfTape]) -> Resolved? {
        guard let tape = shelf.first(where: { $0.tape.uuid == tapeUUID }), let first = tape.items.first else {
            return nil
        }
        guard let index = tape.items.firstIndex(where: { $0.source.id == sourceID }) else {
            guard let firstID = first.source.id else { return nil }
            let start = WorkPosition(tapeUUID: tapeUUID, tab: tab, sourceID: firstID, playhead: 0)
            return Resolved(tape: tape, itemIndex: 0, position: start)
        }
        let duration = max(0, tape.items[index].source.duration)
        var position = self
        position.playhead = playhead.isFinite ? min(duration, max(0, playhead)) : 0
        if let zoomStart, let zoomSpan, zoomStart.isFinite, zoomSpan.isFinite, duration > 0 {
            let span = min(duration, max(Self.minimumZoomSpan, zoomSpan))
            position.zoomSpan = span
            position.zoomStart = max(0, min(duration - span, zoomStart))
        } else {
            position.zoomStart = nil
            position.zoomSpan = nil
        }
        return Resolved(tape: tape, itemIndex: index, position: position)
    }
}
