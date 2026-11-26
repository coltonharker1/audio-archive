import Foundation
import GRDB
import Testing
@testable import RemanenceCore

@Suite struct WaveformTests {
    private static let loud = UInt8(220)
    private static let hiss = UInt8(40)

    /// Builds a waveform from (seconds, level) stretches.
    private func waveform(_ parts: [(Double, UInt8)]) -> Waveform {
        var rms: [UInt8] = []
        for (seconds, level) in parts {
            rms += [UInt8](repeating: level, count: Int(seconds * 100))
        }
        return Waveform(peaks: rms, rms: rms)
    }

    @Test func surviviesARoundTripToDisk() throws {
        let original = waveform([(1, Self.loud), (0.5, Self.hiss)])
        let restored = try Waveform(encoded: original.encoded())
        #expect(restored == original)
        #expect(abs(restored.duration - 1.5) < 0.001)
    }

    @Test func rejectsDamagedFiles() {
        #expect(throws: Waveform.WaveformError.self) { try Waveform(encoded: Data("nope".utf8)) }
        #expect(throws: Waveform.WaveformError.self) { try Waveform(encoded: waveform([(1, 10)]).encoded().dropLast(3)) }
    }

    @Test func readsDecodedAudio() throws {
        // One second of silence, then one second at half scale.
        var samples = [Int16](repeating: 0, count: 8000)
        samples += [Int16](repeating: 16384, count: 8000)
        samples += [Int16](repeating: 5, count: 30) // A partial bin at the end is dropped.
        let url = TestFolders.file("wave.raw")
        defer { try? FileManager.default.removeItem(at: url) }
        try samples.withUnsafeBytes { Data($0) }.write(to: url)

        let waveform = try Waveform(decodedAudioAt: url)

        #expect(waveform.peaks.count == 200)
        #expect(waveform.peaks[50] == 0)
        // Half scale is about -6 dB, which sits high on the scale.
        #expect((230...240).contains(waveform.peaks[150]))
        #expect(waveform.rms[150] == waveform.peaks[150])
    }

    @Test func readsAudioLongerThanOneReadChunk() throws {
        let seconds = 130
        let samples = [Int16](repeating: 1000, count: 8000 * seconds)
        let url = TestFolders.file("wave.raw")
        defer { try? FileManager.default.removeItem(at: url) }
        try samples.withUnsafeBytes { Data($0) }.write(to: url)

        #expect(try Waveform(decodedAudioAt: url).peaks.count == seconds * 100)
    }

    @Test func columnsShowTheLoudestMoment() {
        // A short loud sound must survive being squeezed into one column.
        let wave = waveform([(5, Self.hiss), (0.01, Self.loud), (5, Self.hiss)])
        let levels = wave.levels(from: 0, to: 10, columns: 1)
        #expect(levels[0] > 0.8)
    }

    @Test func averagesRevealGapsThatPeaksHide() {
        // Each column holds a gap with one short loud moment inside it.
        let wave = waveform([(10, Self.loud), (9.9, Self.hiss), (0.1, Self.loud), (10, Self.loud)])
        let peak = wave.levels(from: 0, to: 30, columns: 3, style: .peak)
        let average = wave.levels(from: 0, to: 30, columns: 3, style: .average)
        #expect(peak[1] > 0.8, "the loudest moment hides the gap")
        #expect(average[1] < 0.2, "the average shows it")
        #expect(average[0] > 0.8)
    }

    @Test func hissSitsNearZeroOnTheScale() {
        let wave = waveform([(10, Self.hiss), (10, Self.loud)])
        let levels = wave.levels(from: 0, to: 20, columns: 2, style: .average)
        #expect(levels[0] <= 0.02)
        #expect(levels[1] == 1 || levels[1] > 0.8)
    }

    @Test func columnsHandleTheEdges() {
        let wave = waveform([(1, Self.loud)])
        #expect(wave.levels(from: 0, to: 1, columns: 0).isEmpty)
        #expect(wave.levels(from: 1, to: 0, columns: 4).isEmpty)
        // Past the end of the audio draws as silence rather than crashing.
        #expect(wave.levels(from: 0.5, to: 2, columns: 3).last == 0)
        #expect(wave.levels(from: 0.5, to: 2, columns: 3, style: .average).last == 0)
        // More columns than bins still works.
        #expect(wave.levels(from: 0, to: 0.01, columns: 50).count == 50)
    }

    @Test func aTimeInLoudAudioMovesToTheNearestGap() throws {
        let wave = waveform([(10, Self.loud), (1, Self.hiss), (10, Self.loud), (1, Self.hiss), (10, Self.loud)])
        let snapped = try #require(wave.nearestQuiet(to: 9))
        #expect(snapped > 10 && snapped < 11)

        let later = try #require(wave.nearestQuiet(to: 12))
        #expect(later > 10 && later < 11, "the earlier gap is closer")
    }

    @Test func aTimeAlreadyInAGapStaysPut() {
        let wave = waveform([(10, Self.loud), (5, Self.hiss), (10, Self.loud)])
        #expect(wave.nearestQuiet(to: 12.3) == 12.3)
    }

    @Test func nothingNearbyMeansNoSnap() {
        let wave = waveform([(1, Self.hiss), (60, Self.loud), (1, Self.hiss), (60, Self.loud)])
        #expect(wave.nearestQuiet(to: 30, within: 3) == nil)
    }

    @Test func aPauseTooShortIsNotAGap() {
        let wave = waveform([(1, Self.hiss), (10, Self.loud), (0.1, Self.hiss), (10, Self.loud), (1, Self.hiss)])
        #expect(wave.nearestQuiet(to: 11.05, within: 2) == nil)
    }

    /// Real gaps are spiky at this resolution, as on RA-005, where its 41-second gap
    /// never stays below the threshold for more than 0.6 s at a time.
    @Test func aGapWithNoiseSpikesStillCountsAsOne() throws {
        var levels = [UInt8](repeating: Self.hiss, count: 3000)
        for index in stride(from: 40, to: 3000, by: 60) {
            for offset in 0..<8 { levels[index + offset] = 150 }
        }
        let loud = [UInt8](repeating: Self.loud, count: 3000)
        let rms = loud + levels + loud
        let wave = Waveform(peaks: rms, rms: rms)

        let snapped = try #require(wave.nearestQuiet(to: 29))
        #expect(snapped > 30 && snapped < 31)
        #expect(wave.nearestQuiet(to: 45) == 45, "the middle of the gap is quiet, spikes and all")
    }

    @Test func quietIsRelativeToEachTapesOwnFloor() throws {
        // On a noisy tape, a level that's loud on a clean tape can be the quiet part.
        let noisy = waveform([(30, 120), (10, 220), (2, 120), (10, 220), (30, 120)])
        #expect(noisy.nearestQuiet(to: 41) == 41)
        let snapped = try #require(noisy.nearestQuiet(to: 39))
        #expect(snapped > 40)
    }
}

@Suite struct MarkerTests {
    let database: AppDatabase
    let library: Library
    let source: Int64

    init() throws {
        let root = try TestFolders.make("markers")
        let paths = LibraryPaths(library: root, support: root)
        try paths.createDirectories()
        database = try AppDatabase.open(at: paths.database)
        library = Library(database: database, paths: paths)
        source = try database.writer.write { db in
            var tape = Tape(uuid: "t", title: "Tape", createdAt: Date())
            try tape.insert(db)
            var source = Source(tapeId: tape.id!, position: 0, masterPath: "m.wav", sha256: "s", duration: 100)
            try source.insert(db)
            var track = Track(sourceId: source.id!, name: "Whole Tape")
            try track.insert(db)
            return source.id!
        }
    }

    private func review() async throws -> Review {
        try await database.writer.read { [source] db in try #require(try Library.fetchReview(db, sourceID: source)) }
    }

    @Test func aRecordingStartsAsOneTrack() async throws {
        let tracks = try await review().tracks
        #expect(tracks.count == 1)
        #expect(tracks[0].start == 0)
        #expect(tracks[0].end == 100)
        #expect(tracks[0].name == "Whole Tape")
        #expect(tracks[0].markerID == nil)
    }

    @Test func markersDivideItIntoNamedTracks() async throws {
        let first = try await library.addMarker(sourceID: source, time: 60)
        let second = try await library.addMarker(sourceID: source, time: 25, trackName: "Hymn")

        let tracks = try await review().tracks
        #expect(tracks.map(\.start) == [0, 25, 60])
        #expect(tracks.map(\.end) == [25, 60, 100])
        #expect(tracks.map(\.markerID) == [nil, second, first])
        #expect(tracks.map(\.name) == ["Whole Tape", "Hymn", nil])
    }

    @Test func movingAMarkerKeepsItsTrackName() async throws {
        let marker = try await library.addMarker(sourceID: source, time: 25, trackName: "Hymn")
        try await library.moveMarker(id: marker, to: 40)

        let tracks = try await review().tracks
        #expect(tracks.map(\.start) == [0, 40])
        #expect(tracks[1].name == "Hymn")
    }

    @Test func aMarkerCanMovePastAnother() async throws {
        let first = try await library.addMarker(sourceID: source, time: 20, trackName: "A")
        _ = try await library.addMarker(sourceID: source, time: 40, trackName: "B")
        try await library.moveMarker(id: first, to: 60)

        let tracks = try await review().tracks
        #expect(tracks.map(\.name) == ["Whole Tape", "B", "A"])
    }

    @Test func deletingAMarkerGivesItsAudioBack() async throws {
        let marker = try await library.addMarker(sourceID: source, time: 25, trackName: "Hymn")
        try await library.deleteMarker(id: marker)

        let tracks = try await review().tracks
        #expect(tracks.count == 1)
        #expect(tracks[0].end == 100)
    }

    @Test func markersMustBeInsideTheRecording() async {
        for time in [-1.0, 0, 100, 500] {
            await #expect(throws: MarkerError.outsideRecording) {
                try await library.addMarker(sourceID: source, time: time)
            }
        }
    }

    @Test func markersCannotStackUp() async throws {
        let marker = try await library.addMarker(sourceID: source, time: 25)
        await #expect(throws: MarkerError.tooCloseToAnother) {
            try await library.addMarker(sourceID: source, time: 25.01)
        }
        // A marker isn't too close to itself, so small nudges work.
        try await library.moveMarker(id: marker, to: 25.01)
        #expect(try await review().markers.first?.time == 25.01)
    }

    @Test func trimsShapeTheFirstAndLastTracks() async throws {
        _ = try await library.addMarker(sourceID: source, time: 50)
        try await library.setTrim(sourceID: source, start: 5, end: 90)

        let result = try await review()
        #expect(result.tracks.map(\.start) == [5, 50])
        #expect(result.tracks.map(\.end) == [50, 90])
        #expect(result.trimStart == 5)
        #expect(result.trimEnd == 90)
    }

    @Test func markersOutsideATrimComeBackWhenItWidens() async throws {
        _ = try await library.addMarker(sourceID: source, time: 95, trackName: "End")
        try await library.setTrim(sourceID: source, start: 0, end: 90)
        #expect(try await review().tracks.count == 1)

        try await library.setTrim(sourceID: source, start: 0, end: nil)
        let tracks = try await review().tracks
        #expect(tracks.count == 2)
        #expect(tracks[1].name == "End")
    }

    @Test func aTrimToTheFullLengthStoresNoEnd() async throws {
        try await library.setTrim(sourceID: source, start: 0, end: 100)
        #expect(try await review().source.trimEnd == nil)
    }

    @Test func impossibleTrimsAreRefused() async {
        for (start, end) in [(50.0, 40.0), (50, 50), (-1, 40), (0, 500)] {
            await #expect(throws: MarkerError.invalidTrim) {
                try await library.setTrim(sourceID: source, start: start, end: end)
            }
        }
    }

    @Test func renamingATrackSavesAndBlankClears() async throws {
        _ = try await library.addMarker(sourceID: source, time: 50)
        let id = try #require(try await review().tracks[1].trackID)

        try await library.renameTrack(id: id, name: "  Sermon ")
        #expect(try await review().tracks[1].name == "Sermon")

        try await library.renameTrack(id: id, name: "   ")
        #expect(try await review().tracks[1].name == nil)
    }

    @Test func theShelfCountsTracksFromMarkers() async throws {
        _ = try await library.addMarker(sourceID: source, time: 50)
        _ = try await library.addMarker(sourceID: source, time: 75)

        let shelf = try await database.writer.read { db in try Library.fetchShelf(db) }
        #expect(shelf.first?.markerCount == 2)
        #expect(shelf.first?.trackCount == 3)
    }

    @Test func aSummaryCoversOnlyItsTrack() async throws {
        // Segments either side of a marker belong to different tracks.
        try await database.writer.write { [source] db in
            for (start, text) in [(10.0, "before the marker"), (60.0, "after the marker")] {
                var segment = Segment(sourceId: source, startTime: start, endTime: start + 1, text: text)
                try segment.insert(db)
            }
        }
        _ = try await library.addMarker(sourceID: source, time: 50, trackName: "Second")
        try await library.requestSummaryCheck(source: source)
    }

    @Test func updatesArriveWhenMarkersChange() async throws {
        var updates = library.reviewUpdates(sourceID: source).makeAsyncIterator()
        #expect(try await updates.next()??.tracks.count == 1)
        _ = try await library.addMarker(sourceID: source, time: 50)
        #expect(try await updates.next()??.tracks.count == 2)
    }

    @Test func peaksAreQueuedOnceForSourcesWithoutThem() async throws {
        try await database.writer.write { db in
            try JobStore.enqueueMissingPeaks(db)
            try JobStore.enqueueMissingPeaks(db)
        }
        let jobs = try await database.writer.read { db in try Job.fetchAll(db) }
        #expect(jobs.map(\.type) == [.peaks])
    }
}

extension Library {
    /// Checks the text a track's summary would be given, using the pipeline's lookup.
    fileprivate func requestSummaryCheck(source: Int64) async throws {
        let (spans, segments) = try await database.writer.read { db in
            let times = try Double.fetchAll(db, sql: "SELECT time FROM marker WHERE source_id = ?", arguments: [source])
            let duration = try Double.fetchOne(db, sql: "SELECT duration FROM source WHERE id = ?", arguments: [source]) ?? 0
            let spans = trackSpans(duration: duration, markers: times)
            let segments = try Segment.filter(Column("source_id") == source).fetchAll(db)
            return (spans, segments)
        }
        #expect(spans.count == 2)
        #expect(segments.filter { $0.startTime >= spans[0].start && $0.startTime < spans[0].end }.map(\.text) == ["before the marker"])
        #expect(segments.filter { $0.startTime >= spans[1].start && $0.startTime < spans[1].end }.map(\.text) == ["after the marker"])
    }
}

@Suite struct WaveformJobTests {
    @Test func aRealFileProducesACachedWaveform() async throws {
        let fixture = try BackupFixture()
        let (database, _, library) = try fixture.open()
        try fixture.addEntry(
            "RA-006", title: "Voicemail", medium: "Microcassette",
            tracks: [.init(title: "Voicemail", audio: "only.wav")]
        )
        let importer = BackupImporter(database: database, paths: fixture.library)
        _ = try await importer.run(from: fixture.folder)
        try await database.writer.write { db in try JobStore.enqueueMissingPeaks(db) }
        let claimed: Job? = try await database.writer.write { db in try JobStore.claimNext(db) }
        let job = try #require(claimed)

        let pipeline = Pipeline(database: database, paths: fixture.library)
        try await pipeline.run(job, context: JobContext(reportProgress: { _ in }, reportPID: { _ in }))

        let source = try await database.writer.read { db in try Source.fetchOne(db)! }
        let path = try #require(source.peaksPath)
        #expect(path == "peaks/RA-006/only.peaks")

        let waveform = try await library.loadWaveform(path: path)
        #expect(abs(waveform.duration - source.duration) < 0.05)
        #expect(waveform.peaks.contains { $0 > 100 }, "the fixture's tone shows up")
    }
}
