/// A stretch of a source between two boundaries, in seconds.
public struct TrackSpan: Equatable, Sendable {
    public let start: Double
    public let end: Double
    /// The marker that begins this span. `nil` for the span at the trim start.
    public let startMarker: Double?

    public var duration: Double { end - start }
}

/// Works out a source's tracks from its trim points and markers.
///
/// Tracks are derived rather than stored, so moving a marker never touches audio.
/// Markers outside the trimmed region are ignored rather than discarded, so they
/// come back into play if the trim is widened.
public func trackSpans(
    duration: Double,
    trimStart: Double = 0,
    trimEnd: Double? = nil,
    markers: [Double]
) -> [TrackSpan] {
    let lower = max(0, trimStart)
    let upper = min(duration, trimEnd ?? duration)
    guard upper > lower else { return [] }

    let boundaries = Set(markers.filter { $0 > lower && $0 < upper }).sorted()
    let starts: [(time: Double, marker: Double?)] =
        [(lower, nil)] + boundaries.map { ($0, $0) }

    return starts.enumerated().map { index, start in
        let end = index + 1 < starts.count ? starts[index + 1].time : upper
        return TrackSpan(start: start.time, end: end, startMarker: start.marker)
    }
}
