import Foundation

/// Carries a moment between Review, which shows one recording at a time, and Edit,
/// which shows a tape's tracks. Both count in seconds of a recording's master, so
/// nothing is converted and nothing is written.
public enum TrackHandoff {
    /// How far short of a track's start a playhead can fall and still count as on
    /// it. A player seeks in steps, so a seek to a marker can land just before it.
    public static let tolerance = 0.005
    /// How far inside its end a track is entered again, since the end of one track
    /// is the start of the next.
    static let inset = 0.01

    /// A moment of one recording's master.
    public struct Place: Equatable, Sendable {
        public let sourceID: Int64
        public let time: Double

        public init(sourceID: Int64, time: Double) {
            self.sourceID = sourceID
            self.time = time
        }
    }

    /// Where Edit opens: a piece with nothing appended to it, and a time it plays.
    public struct Arrival: Equatable, Sendable {
        public let piece: PostTrack
        public let time: Double
    }

    /// Which of a recording's stretches a time belongs to, given where each one
    /// starts, in any order. That's the last to have started by then, or the first
    /// of them when the time comes before all of them.
    public static func index(at time: Double, starts: [Double]) -> Int? {
        let begun = starts.indices.filter { starts[$0] <= time + tolerance }
        return begun.max { starts[$0] < starts[$1] }
            ?? starts.indices.min { starts[$0] < starts[$1] }
    }

    /// The moment to hand on when the screen names the track holding `shown`, but
    /// the player has since got to `precise`. The screen's time updates only a few
    /// times a second, so just past a marker it can still name the earlier track.
    /// A precise time on another track is kept inside the named one, short of
    /// where the next starts, so what opens is the track the screen names.
    public static func time(_ precise: Double, onTrackAt shown: Double, starts: [Double]) -> Double {
        guard let named = index(at: shown, starts: starts), index(at: precise, starts: starts) != named else {
            return precise
        }
        let start = starts[named]
        let last = starts.filter { $0 > start }.min().map { max(start, $0 - inset) } ?? precise
        return min(last, max(start, precise))
    }

    /// The piece holding a moment of a recording, whether it's a track of its own or
    /// appended to one, and the nearest time to that moment which it plays. A moment
    /// trimmed off the track or the recording goes to the nearest edge of what's
    /// kept. Nil when no piece comes from the recording.
    public static func arrival(sourceID: Int64, time: Double, in tracks: [PostTrack]) -> Arrival? {
        let pieces = tracks.flatMap(\.pieces).filter { $0.sourceID == sourceID }
        let time = time.isFinite ? time : 0
        guard let index = index(at: time, starts: pieces.map(\.spanStart)) else { return nil }
        let piece = pieces[index]
        return Arrival(piece: piece, time: min(piece.end, max(piece.start, time)))
    }

    /// Where Review goes from a moment of a piece. It stays inside what the piece
    /// plays, short of its very end, so going back to Edit finds the same piece.
    public static func place(in piece: PostTrack, at time: Double) -> Place {
        let last = max(piece.start, piece.end - inset)
        let time = time.isFinite ? time : piece.start
        return Place(sourceID: piece.sourceID, time: min(last, max(piece.start, time)))
    }

    /// Where a zoomed view should start to show a time at the span it had. It stays
    /// put while the time is in it, and centres on the time otherwise.
    public static func zoomStart(_ start: Double, span: Double, showing time: Double, duration: Double) -> Double {
        let moved = time >= start && time <= start + span ? start : time - span / 2
        return max(0, min(duration - span, moved))
    }

    /// "Return to Side A", for a button as wide as its words.
    public static func returnTitle(side: String?) -> String {
        guard let side, !side.isEmpty else { return "Return to Review" }
        let name = side.count > 12 ? side.prefix(11).trimmingCharacters(in: .whitespaces) + "…" : side
        return "Return to Side \(name)"
    }
}
