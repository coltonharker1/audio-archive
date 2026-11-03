import AVFoundation
import CoreAudio
import Foundation
import GRDB
import Testing
@testable import RemanenceCore

@Suite struct CaptureFileTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "remanence-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// One second of a tone, as 24-bit samples.
    private func tone(frames: Int, channels: Int, amplitude: Float = 0.5) -> Data {
        let wave = (0..<frames).map { sin(Float($0) * 2 * .pi * 440 / 48000) * amplitude }
        return wave.withUnsafeBufferPointer { pointer in
            CaptureFile.interleave(Array(repeating: pointer.baseAddress!, count: channels), frames: frames)
        }
    }

    private func write(_ name: String, seconds: Int, channels: Int = 1, rate: Double = 48000, close: Bool) throws -> URL {
        let url = directory.appending(path: name)
        let file = try CaptureFile(url: url, sampleRate: rate, channels: channels)
        for _ in 0..<seconds {
            try file.append(tone(frames: Int(rate), channels: channels), frames: Int(rate))
        }
        if close { try file.close() }
        return url
    }

    @Test func aClosedFileHasTheRightDetails() async throws {
        let url = try write("closed.caf", seconds: 2, channels: 2, close: true)
        let details = try await probeAudio(url)
        #expect(abs(details.duration - 2) < 0.01)
        #expect(details.sampleRate == 48000)
        #expect(details.channels == 2)
        #expect(details.bitDepth == 24)
    }

    /// The core promise: a file that never got closed, as after a crash or power
    /// loss, is still a valid recording with all its audio.
    @Test func aFileThatWasNeverClosedIsStillValid() async throws {
        let url = try write("crashed.caf", seconds: 3, close: false)

        let details = try await probeAudio(url)
        #expect(abs(details.duration - 3) < 0.01)

        let audio = try AVAudioFile(forReading: url)
        #expect(audio.length == 3 * 48000)
        #expect(audio.fileFormat.sampleRate == 48000)
    }

    @Test func aFileCutOffMidSampleStillReads() async throws {
        let url = try write("cut.caf", seconds: 1, close: false)
        let handle = try FileHandle(forWritingTo: url)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - 1)
        try handle.close()

        let audio = try AVAudioFile(forReading: url)
        #expect(audio.length == 48000 - 1)
    }

    @Test func aRecordingHasNoSizeLimitInItsHeader() throws {
        let header = CaptureFile.header(sampleRate: 96000, channels: 2)
        let size = header.data.subdata(in: header.sizeOffset..<(header.sizeOffset + 8))
        #expect(size == Data(repeating: 0xFF, count: 8), "-1 means until the end of the file")
    }

    @Test func samplesSurviveTheRoundTrip() throws {
        let url = try write("values.caf", seconds: 1, close: true)
        let audio = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 48000))
        try audio.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])

        for index in stride(from: 0, to: 48000, by: 997) {
            let expected = sin(Float(index) * 2 * .pi * 440 / 48000) * 0.5
            #expect(abs(samples[index] - expected) < 0.000_01)
        }
    }

    @Test func overloadedSamplesAreLimitedRatherThanWrapping() {
        let samples: [Float] = [2, -2, 1, -1, 0]
        let data = samples.withUnsafeBufferPointer { CaptureFile.interleave([$0.baseAddress!], frames: 5) }
        func value(at index: Int) -> Int32 {
            let raw = Int32(data[index * 3]) | Int32(data[index * 3 + 1]) << 8 | Int32(data[index * 3 + 2]) << 16
            return (raw << 8) >> 8
        }
        #expect(value(at: 0) == 8_388_607)
        #expect(value(at: 1) == -8_388_607)
        #expect(value(at: 4) == 0)
    }

    @Test func channelsAreInterleavedInOrder() {
        let left: [Float] = [0.5, 0.5]
        let right: [Float] = [-0.5, -0.5]
        let data = left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                CaptureFile.interleave([l.baseAddress!, r.baseAddress!], frames: 2)
            }
        }
        #expect(data.count == 12)
        #expect(data[2] == 0x3F, "left is positive")
        #expect(data[5] == 0xC0, "right is negative")
    }
}

@Suite struct InputDeviceTests {
    private func device(_ name: String, _ kind: InputDevice.Kind) -> InputDevice {
        InputDevice(id: 1, uid: name, name: name, channels: 2, kind: kind)
    }

    /// A silent virtual input from Teams was once chosen ahead of the real microphone.
    @Test func realInterfacesComeFirstAndVirtualInputsLast() {
        let ordered = InputDevice.ordered([
            device("Microsoft Teams Audio", .virtual),
            device("MacBook Pro Microphone", .builtIn),
            device("Bluetooth", .other),
            device("Scarlett", .interface),
        ])
        #expect(ordered.map(\.name) == ["Scarlett", "MacBook Pro Microphone", "Bluetooth", "Microsoft Teams Audio"])
    }

    @Test func hardwareTypesAreRecognized() {
        #expect(InputDevice.Kind(transport: kAudioDeviceTransportTypeUSB) == .interface)
        #expect(InputDevice.Kind(transport: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
        #expect(InputDevice.Kind(transport: kAudioDeviceTransportTypeVirtual) == .virtual)
        #expect(InputDevice.Kind(transport: kAudioDeviceTransportTypeAggregate) == .virtual)
        #expect(InputDevice.Kind(transport: kAudioDeviceTransportTypeBluetooth) == .other)
    }
}

@Suite struct LevelAnalysisTests {
    private func levels(_ samples: [Float]) -> BlockLevels {
        samples.withUnsafeBufferPointer { BlockLevels(samples: $0) }
    }

    @Test func measuresPeakAndRMS() {
        let block = levels([0.5, -0.5, 0.5, -0.5])
        #expect(abs(block.peak - -6.02) < 0.01)
        #expect(abs(block.rms - -6.02) < 0.01)
        #expect(!block.clipped)
    }

    @Test func silenceIsVeryLow() {
        let block = levels([0, 0, 0])
        #expect(block.peak == -140)
        #expect(block.rms == -140)
    }

    @Test func clippingNeedsSeveralPinnedSamples() {
        #expect(!levels([0.2, 1, 0.2, 1, 1, 0.2]).clipped, "a brief touch of full scale isn't clipping")
        #expect(levels([0.2, 1, -1, 1, 0.2]).clipped)
    }

    @Test(arguments: [
        (-70.0, LevelAdvice.noSignal),
        (-50, .tooQuiet),
        (-40, .fine),
        (-20, .fine),
        (-12, .good),
        (-6, .good),
        (-3, .good),
        (-2, .hot),
        (-0.05, .clipping),
    ])
    func advice(peak: Double, expected: LevelAdvice) {
        #expect(LevelAdvice.assess(peak: peak, clipped: false) == expected)
    }

    @Test func detectedClippingWinsAtAnyLevel() {
        #expect(LevelAdvice.assess(peak: -20, clipped: true) == .clipping)
    }

    @Test func theNeedleSettlesAtTheRightPlace() {
        var meter = VUBallistics()
        for _ in 0..<100 { meter.update(rms: -18, seconds: 0.05) }
        #expect(abs(meter.vu) < 0.1, "-18 dBFS reads 0 VU")
    }

    @Test func theNeedleTakesAboutAThirdOfASecondToRise() {
        var meter = VUBallistics()
        for _ in 0..<6 { meter.update(rms: -18, seconds: 0.05) }
        // 99% of the way in power terms after 300 ms is about -18 dB.
        #expect(abs(meter.level - -18) < 1)

        var early = VUBallistics()
        early.update(rms: -18, seconds: 0.05)
        #expect(early.level < -22, "it doesn't jump instantly")
    }

    @Test func recentPeaksForgetOldSounds() {
        var recent = RecentPeaks(seconds: 3)
        recent.add(peak: -5, clipped: true, seconds: 0.5)
        #expect(recent.peak == -5)
        #expect(recent.clipped)
        for _ in 0..<10 { recent.add(peak: -30, clipped: false, seconds: 0.5) }
        #expect(recent.peak == -30)
        #expect(!recent.clipped)
        #expect(recent.advice == .fine)
    }

    private func check(_ a: [Float], _ b: [Float]) -> ChannelCheck.Finding {
        var check = ChannelCheck()
        a.withUnsafeBufferPointer { left in
            b.withUnsafeBufferPointer { right in check.add(left, right) }
        }
        return check.finding
    }

    private var tone: [Float] { (0..<1000).map { sin(Float($0) * 0.1) * 0.5 } }
    private var other: [Float] { (0..<1000).map { sin(Float($0) * 0.37) * 0.5 } }

    @Test func channelCheckFindsEachCase() {
        let silence = [Float](repeating: 0, count: 1000)
        #expect(check(silence, silence) == .notEnoughSound)
        #expect(check(tone, other) == .stereo)
        #expect(check(tone, tone) == .identical)
        #expect(check(tone, silence) == .onlyFirst)
        #expect(check(silence, tone) == .onlySecond)
    }

    @Test func aFaintCrosstalkStillCountsAsADeadChannel() {
        let faint = tone.map { $0 * 0.001 }
        #expect(check(tone, faint) == .onlyFirst)
    }
}

@Suite struct TapeEndDetectorTests {
    /// Feeds whole seconds at a level, returning the first second it said finished.
    private func feed(_ detector: inout TapeEndDetector, level: Double, seconds: Int) -> Int? {
        for second in 0..<seconds {
            // Four blocks a second, like real audio buffers.
            var finished = false
            for _ in 0..<4 where detector.add(rms: level, seconds: 0.25) { finished = true }
            if finished { return second }
        }
        return nil
    }

    /// Speech with hissy pauses, like a playing tape.
    private func playTape(_ detector: inout TapeEndDetector, seconds: Int) -> Int? {
        for second in 0..<seconds {
            let level = second % 4 == 0 ? -50.0 : -25.0
            if feed(&detector, level: level, seconds: 1) != nil { return second }
        }
        return nil
    }

    @Test func aPlayingTapeIsNeverFlagged() {
        var detector = TapeEndDetector()
        #expect(playTape(&detector, seconds: 500) == nil)
    }

    @Test func hissDisappearingIsNoticedQuickly() throws {
        var detector = TapeEndDetector()
        _ = playTape(&detector, seconds: 120)
        let when = try #require(feed(&detector, level: -90, seconds: 30))
        #expect((8...11).contains(when), "about ten seconds below the hiss")
    }

    @Test func aMinuteOfOnlyHissIsNoticedToo() throws {
        var detector = TapeEndDetector()
        _ = playTape(&detector, seconds: 200)
        let when = try #require(feed(&detector, level: -50, seconds: 90))
        #expect((55...62).contains(when))
    }

    @Test func aBriefPauseIsNotAnEnding() {
        var detector = TapeEndDetector()
        _ = playTape(&detector, seconds: 120)
        #expect(feed(&detector, level: -50, seconds: 30) == nil)
        #expect(playTape(&detector, seconds: 60) == nil)
    }

    @Test func thereIsNoGuessingBeforeThereIsHistory() {
        var detector = TapeEndDetector()
        #expect(feed(&detector, level: -90, seconds: 20) == nil)
    }

    @Test func aDismissedQuestionStaysQuietUntilSoundReturns() throws {
        var detector = TapeEndDetector()
        _ = playTape(&detector, seconds: 120)
        _ = try #require(feed(&detector, level: -90, seconds: 30))

        detector.dismiss()
        #expect(feed(&detector, level: -90, seconds: 60) == nil)
    }
}

@Suite struct CaptureLifecycleTests {
    let fixture: BackupFixture
    let database: AppDatabase
    let library: Library

    init() throws {
        fixture = try BackupFixture()
        (database, _, library) = try fixture.open()
    }

    private func machine(_ name: String) async throws -> Machine {
        let machines = try await library.machines()
        return try #require(machines.first { $0.name == name })
    }

    private func writeAudio(to url: URL, seconds: Int = 2, close: Bool = true) throws {
        let file = try CaptureFile(url: url, sampleRate: 48000, channels: 1)
        let silence = Data(count: 48000 * 3)
        for _ in 0..<seconds { try file.append(silence, frames: 48000) }
        if close { try file.close() }
    }

    private func jobs() async throws -> [JobType] {
        try await database.writer.read { db in try Job.order(Column("id")).fetchAll(db).map(\.type) }
    }

    @Test func yourFourMachinesAreReady() async throws {
        let machines = try await library.machines()
        #expect(machines.map(\.name) == ["7\" Reel", "5\" Reel", "Cassette", "Microcassette"])
        #expect(machines[0].speedOptions.first == "7½ ips")
        #expect(machines[3].speedOptions == ["2.4 cm/s", "1.2 cm/s"])
        #expect(TapeFormat(medium: machines[0].medium) == .sevenInchReel)
        #expect(TapeFormat(medium: machines[1].medium) == .fiveInchReel)
        #expect(TapeFormat(medium: machines[2].medium) == .cassette)
        #expect(TapeFormat(medium: machines[3].medium) == .microcassette)
    }

    @Test func machineSettingsAreRemembered() async throws {
        let reel = try await machine("7\" Reel")
        try await library.updateMachine(id: reel.id!, knobNote: "Output at 6", deviceUID: "scarlett", channelMode: "left")
        let updated = try await machine("7\" Reel")
        #expect(updated.knobNote == "Output at 6")
        #expect(updated.deviceUid == "scarlett")
        #expect(updated.channelMode == "left")
    }

    @Test func aTapeIsRecordedBeforeAnyAudioArrives() async throws {
        let target = try await library.beginCapture(machine: try await machine("Cassette"), title: "Dad's Tape", speed: "1⅞ ips")
        let tape = try await database.writer.read { db in try Tape.fetchOne(db)! }
        #expect(tape.title == "Dad's Tape")
        #expect(tape.medium == "Cassette")
        #expect(tape.speed == "1⅞ ips")
        #expect(!tape.titleIsProvisional)
        #expect(target.side == "A")
        #expect(target.url.lastPathComponent == "side-a.caf")
        #expect(try await jobs().isEmpty, "nothing processes a file still being written")
    }

    @Test func anUnnamedTapeGetsAProvisionalTitle() async throws {
        _ = try await library.beginCapture(machine: nil, title: "   ", speed: nil)
        let tape = try await database.writer.read { db in try Tape.fetchOne(db)! }
        #expect(tape.title.hasPrefix("Recording, "))
        #expect(tape.titleIsProvisional)
    }

    @Test func finishingProtectsTheMasterAndQueuesWorkButNoSummary() async throws {
        let target = try await library.beginCapture(machine: try await machine("7\" Reel"), title: "T", speed: nil)
        try writeAudio(to: target.url)

        try await library.finishCapture(sourceID: target.sourceID)

        let source = try await database.writer.read { db in try Source.fetchOne(db, key: target.sourceID)! }
        #expect(source.sha256?.count == 64)
        #expect(abs(source.duration - 2) < 0.01)
        #expect(source.bitDepth == 24)
        #expect(!FileManager.default.isWritableFile(atPath: target.url.path))
        #expect(try await jobs() == [.prep, .transcribe, .peaks])
        let model = try await database.writer.read { db in try Job.filter(Column("type") == "transcribe").fetchOne(db)?.model }
        #expect(model == "base", "this temporary library has no medium model")
    }

    @Test func markersFromCaptureBecomeTracks() async throws {
        let target = try await library.beginCapture(machine: nil, title: "T", speed: nil)
        try writeAudio(to: target.url)

        try await library.finishCapture(sourceID: target.sourceID, markers: [0.5, 1.5, 99])

        let review = try await database.writer.read { db in try Library.fetchReview(db, sourceID: target.sourceID) }
        #expect(review?.markers.map(\.time) == [0.5, 1.5], "a marker beyond the end is dropped")
        #expect(review?.tracks.count == 3)
        #expect(review?.tracks.first?.name == "Side A")
    }

    @Test func aSecondSideJoinsTheSameTape() async throws {
        let first = try await library.beginCapture(machine: nil, title: "T", speed: nil)
        try writeAudio(to: first.url)
        try await library.finishCapture(sourceID: first.sourceID)

        let second = try await library.beginNextSide(tapeID: first.tapeID)
        try writeAudio(to: second.url)
        try await library.finishCapture(sourceID: second.sourceID)

        #expect(second.tapeID == first.tapeID)
        #expect(second.side == "B")
        #expect(second.url.lastPathComponent == "side-b.caf")

        let shelf = try await database.writer.read { db in try Library.fetchShelf(db) }
        #expect(shelf.count == 1)
        #expect(shelf[0].items.map(\.name) == ["Side A", "Side B"])
    }

    /// The crash test: the app dies mid-recording, and on the next launch the audio
    /// so far is on the shelf and queued for processing.
    @Test func anInterruptedRecordingIsRecoveredAtLaunch() async throws {
        let target = try await library.beginCapture(machine: nil, title: "Lost Power", speed: nil)
        try writeAudio(to: target.url, seconds: 3, close: false)

        let recovered = try await library.recoverInterruptedCaptures()

        #expect(recovered == ["Lost Power"])
        let source = try await database.writer.read { db in try Source.fetchOne(db, key: target.sourceID)! }
        #expect(abs(source.duration - 3) < 0.01)
        #expect(source.sha256 != nil)
        #expect(try await jobs() == [.prep, .transcribe, .peaks])
        #expect(try await library.recoverInterruptedCaptures().isEmpty, "only once")
    }

    @Test func aRecordingThatNeverGotAudioIsClearedAway() async throws {
        let target = try await library.beginCapture(machine: nil, title: "Nothing", speed: nil)
        try writeAudio(to: target.url, seconds: 0, close: false)

        #expect(try await library.recoverInterruptedCaptures().isEmpty)

        let shelf = try await database.writer.read { db in try Library.fetchShelf(db) }
        #expect(shelf.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.url.path))
        #expect(!FileManager.default.fileExists(atPath: target.url.deletingLastPathComponent().path), "no empty folder left")
    }

    @Test func clearingAnEmptySideKeepsTheRestOfTheTape() async throws {
        let first = try await library.beginCapture(machine: nil, title: "T", speed: nil)
        try writeAudio(to: first.url)
        try await library.finishCapture(sourceID: first.sourceID)
        let second = try await library.beginNextSide(tapeID: first.tapeID)
        try writeAudio(to: second.url, seconds: 0, close: false)

        try await library.finishCapture(sourceID: second.sourceID)

        let shelf = try await database.writer.read { db in try Library.fetchShelf(db) }
        #expect(shelf.first?.items.map(\.name) == ["Side A"])
    }

    /// Two blank sides can be identical. Saving a recording must never fail for it.
    @Test func identicalRecordingsAreBothKept() async throws {
        let first = try await library.beginCapture(machine: nil, title: "A", speed: nil)
        try writeAudio(to: first.url)
        try await library.finishCapture(sourceID: first.sourceID)

        let second = try await library.beginCapture(machine: nil, title: "B", speed: nil)
        try writeAudio(to: second.url)
        try await library.finishCapture(sourceID: second.sourceID)

        let hashes = try await database.writer.read { db in try Source.order(Column("id")).fetchAll(db).map(\.sha256) }
        #expect(hashes.count == 2)
        #expect(hashes[0]?.count == 64)
        #expect(hashes[1]?.hasPrefix(hashes[0]!) == true)
        #expect(hashes[0] != hashes[1])
    }

    @Test func aDamagedFileDoesNotBlockRecoveringOthers() async throws {
        let bad = try await library.beginCapture(machine: nil, title: "Damaged", speed: nil)
        try Data(repeating: 0x41, count: 5000).write(to: bad.url)
        let good = try await library.beginCapture(machine: nil, title: "Fine", speed: nil)
        try writeAudio(to: good.url, close: false)

        #expect(try await library.recoverInterruptedCaptures() == ["Fine"])
        #expect(FileManager.default.fileExists(atPath: bad.url.path), "kept, not thrown away")
    }

    @Test func aRecordingInProgressIsNotPickedUpForProcessing() async throws {
        let target = try await library.beginCapture(machine: nil, title: "T", speed: nil)
        try writeAudio(to: target.url, close: false)
        try await database.writer.write { db in
            try JobStore.enqueueMissingTranscripts(db) { _ in true }
            try JobStore.enqueueMissingPeaks(db)
        }
        #expect(try await jobs().isEmpty)
    }
}
