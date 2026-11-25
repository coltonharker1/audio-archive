import Synchronization

/// Keeps the last few sets of levels worked out from a waveform, so a view that
/// redraws without changing what it shows doesn't work them out again.
///
/// It holds levels for one waveform at a time: asking about a different one drops
/// everything held. It's safe to use from any thread.
public final class WaveformLevelsCache: Sendable {
    /// The most sets of levels held. At `Waveform.maximumColumns` each, that's
    /// about 128 KB.
    static let capacity = 8

    private struct Key: Equatable {
        let start: Double
        let end: Double
        let columns: Int
        let style: Waveform.Style
        let gainDB: Double
    }

    private struct State {
        var waveform: Waveform?
        /// The most recently used is last.
        var entries: [(key: Key, levels: [Float])] = []
        var hits = 0
        var misses = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// The same result as `Waveform.levels`, remembered from last time when possible.
    public func levels(
        of waveform: Waveform,
        from start: Double,
        to end: Double,
        columns: Int,
        style: Waveform.Style = .peak,
        gainDB: Double = 0
    ) -> [Float] {
        let key = Key(
            start: start, end: end, columns: min(columns, Waveform.maximumColumns),
            style: style, gainDB: gainDB
        )
        return state.withLock { state in
            // Quick for the same copy, which shares its storage.
            if state.waveform != waveform {
                state.waveform = waveform
                state.entries = []
            }
            if let index = state.entries.lastIndex(where: { $0.key == key }) {
                state.hits += 1
                let entry = state.entries.remove(at: index)
                state.entries.append(entry)
                return entry.levels
            }
            state.misses += 1
            let levels = waveform.levels(from: start, to: end, columns: columns, style: style, gainDB: gainDB)
            if state.entries.count >= Self.capacity { state.entries.removeFirst() }
            state.entries.append((key, levels))
            return levels
        }
    }

    /// Forgets everything, including the waveform.
    public func removeAll() {
        state.withLock { state in
            state.waveform = nil
            state.entries = []
        }
    }

    /// How often levels were already held, and how often they had to be worked out.
    var counts: (hits: Int, misses: Int) {
        state.withLock { ($0.hits, $0.misses) }
    }

    /// How many sets of levels are held now.
    var entryCount: Int {
        state.withLock { $0.entries.count }
    }
}
