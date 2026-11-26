import AVFoundation
import CoreAudio
import Foundation
import GRDB
import Testing
@testable import RemanenceCore

@Suite struct CaptureFileTests {
    let directory: URL

    init() throws {
        directory = try TestFolders.make("capture")
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

@Suite struct MachineStopDetectorTests {
    /// Stand-ins for what the Teac gives through the Scarlett: a stopped machine's
    /// noise, blank tape about 6 dB above it, and a recording on the tape.
    enum Sound {
        case stopped, blankTape, program
        /// Stopped, with the loose end of the tape slapping the reel every 3 s.
        case stoppedWithSlaps
    }

    /// Feeds whole seconds of a sound at 8 kHz in 100 ms blocks, returning the first
    /// second the machine looked stopped.
    struct Feeder {
        var detector: MachineStopDetector = {
            var detector = MachineStopDetector()
            detector.beginRecording()
            return detector
        }()
        var seed: UInt64 = 1
        let rate = 8000.0

        mutating func noise() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: seed >> 1) % 2_000_001 - 1_000_000) / 1_000_000
        }

        @discardableResult
        mutating func feed(_ sound: Sound, seconds: Int, stopOnFlag: Bool = true) -> Int? {
            var flagged: Int?
            var phase = 0.0
            for second in 0..<seconds {
                for tenth in 0..<10 {
                    var block = [Float](repeating: 0, count: Int(rate / 10))
                    for index in block.indices {
                        switch sound {
                        case .stopped: block[index] = 0.000_05 * noise()
                        case .stoppedWithSlaps:
                            block[index] = 0.000_05 * noise()
                            if second % 3 == 0, tenth == 0, index < 200 { block[index] += 0.05 * noise() }
                        case .blankTape: block[index] = 0.000_1 * noise()
                        case .program:
                            phase += 2 * .pi * 800 / rate
                            block[index] = 0.1 * Float(sin(phase)) + 0.000_1 * noise()
                        }
                    }
                    block.withUnsafeBufferPointer { detector.add([$0], sampleRate: rate) }
                }
                if detector.machineStopped, flagged == nil {
                    flagged = second
                    if stopOnFlag { return second }
                }
            }
            return flagged
        }

        /// A tape with recordings separated by long blank gaps.
        mutating func playTape(minutes: Int) -> Int? {
            for _ in 0..<minutes {
                if let when = feed(.program, seconds: 20) { return when }
                if let when = feed(.blankTape, seconds: 40) { return when }
            }
            return nil
        }
    }

    @Test func blankGapsOnATapeAreNeverFlagged() {
        var feeder = Feeder()
        feeder.feed(.stopped, seconds: 3)
        #expect(feeder.playTape(minutes: 6) == nil)
        #expect(feeder.feed(.blankTape, seconds: 300) == nil, "five minutes of blank tape")
        #expect(feeder.playTape(minutes: 2) == nil)
    }

    @Test func theMachineStoppingIsNoticedQuickly() throws {
        var feeder = Feeder()
        feeder.feed(.stopped, seconds: 3)
        _ = feeder.playTape(minutes: 3)
        let result1 = feeder.feed(.stopped, seconds: 30)
        let when = try #require(result1)
        #expect((7...9).contains(when), "about eight seconds after it stops")
    }

    @Test func itWorksWithoutHearingTheMachineStoppedFirst() throws {
        // Play pressed before Record, so the stopped floor isn't known until the end.
        // With nothing to compare with, it waits a minute.
        var feeder = Feeder()
        _ = feeder.playTape(minutes: 3)
        let result2 = feeder.feed(.stopped, seconds: 90)
        let when = try #require(result2)
        #expect((58...61).contains(when))
    }

    @Test func aFirstGapOnADenseTapeIsNotAStop() {
        // Play pressed before Record, then a tape with no gaps until a 30-second one.
        var feeder = Feeder()
        _ = feeder.feed(.program, seconds: 600)
        #expect(feeder.feed(.blankTape, seconds: 30) == nil)
        #expect(feeder.feed(.program, seconds: 60) == nil)
    }

    @Test func aTapeNoQuieterThanAStoppedMachineIsLeftAlone() {
        // If running tape can't be told from a stopped machine, nothing is said.
        var feeder = Feeder()
        feeder.feed(.stopped, seconds: 60)
        _ = feeder.feed(.program, seconds: 20)
        #expect(feeder.feed(.stopped, seconds: 120) == nil)
    }

    @Test func theReelsLooseEndSlappingDoesNotHideTheStop() throws {
        var feeder = Feeder()
        feeder.feed(.stopped, seconds: 3)
        _ = feeder.playTape(minutes: 3)
        let result = feeder.feed(.stoppedWithSlaps, seconds: 30)
        let when = try #require(result)
        #expect((7...9).contains(when))
    }

    @Test func listeningBeforeRecordTeachesTheStoppedFloor() {
        // Play pressed before Record, on a tape with no gaps until a long one. Having
        // heard the machine stopped while listening, the gap isn't mistaken for a stop.
        var feeder = Feeder()
        feeder.detector = MachineStopDetector()
        feeder.feed(.stopped, seconds: 40)
        feeder.detector.beginRecording()
        #expect(feeder.feed(.program, seconds: 600) == nil)
        #expect(feeder.feed(.blankTape, seconds: 90) == nil)
    }

    @Test func onlyTheLastHalfMinuteOfListeningCounts() {
        // Knobs turned down long before Record shouldn't leave a floor that's too low.
        var feeder = Feeder()
        feeder.detector = MachineStopDetector()
        for _ in 0..<40 { feeder.feed(.program, seconds: 1) }
        feeder.detector.beginRecording()
        #expect(feeder.feed(.program, seconds: 5) == nil)
    }

    @Test func nothingIsSaidBeforeThereIsHistory() {
        var feeder = Feeder()
        _ = feeder.feed(.blankTape, seconds: 10)
        #expect(feeder.feed(.stopped, seconds: 20) == nil)
    }

    @Test func itStaysStoppedThroughALongIdle() throws {
        var feeder = Feeder()
        feeder.feed(.stopped, seconds: 3)
        _ = feeder.playTape(minutes: 2)
        let result3 = feeder.feed(.stopped, seconds: 20)
        _ = try #require(result3)
        _ = feeder.feed(.stopped, seconds: 600)
        #expect(feeder.detector.machineStopped, "ten minutes later, still stopped")
    }

    @Test func itClearsWhenTheTapeRunsAgain() throws {
        var feeder = Feeder()
        feeder.feed(.stopped, seconds: 3)
        _ = feeder.playTape(minutes: 2)
        let result4 = feeder.feed(.stopped, seconds: 20)
        _ = try #require(result4)
        feeder.feed(.blankTape, seconds: 2)
        #expect(!feeder.detector.machineStopped)
    }

    @Test func keepRecordingWaitsForTheTapeToRunAgain() throws {
        var feeder = Feeder()
        feeder.feed(.stopped, seconds: 3)
        _ = feeder.playTape(minutes: 2)
        let result5 = feeder.feed(.stopped, seconds: 20)
        _ = try #require(result5)

        feeder.detector.dismiss()
        #expect(feeder.feed(.stopped, seconds: 120) == nil)

        // Rethreaded and played on, then it stops again.
        _ = feeder.playTape(minutes: 2)
        let result6 = feeder.feed(.stopped, seconds: 30)
        let again = try #require(result6)
        #expect((7...9).contains(again))
    }

    /// Runs every master in a real library through the detector and prints each time
    /// it would have asked. Only reads the files. Set REMANENCE_STOP_CHECK to the
    /// library folder; build with `-c release`, or it takes a long time.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REMANENCE_STOP_CHECK"] != nil))
    func realMasters() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REMANENCE_STOP_CHECK"]!)
            .appending(path: "masters")
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".caf") || $0.hasSuffix(".wav") }.sorted()
        for path in files {
            let file = try AVAudioFile(forReading: root.appending(path: path), commonFormat: .pcmFormatFloat32, interleaved: false)
            let rate = file.processingFormat.sampleRate
            let channels = Int(file.processingFormat.channelCount)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            var detector = MachineStopDetector()
            detector.beginRecording()
            var read = 0.0
            var asked: [String] = []
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: 4096)
                let count = Int(buffer.frameLength)
                guard count > 0, let data = buffer.floatChannelData else { break }
                detector.add((0..<min(channels, 2)).map { UnsafeBufferPointer(start: data[$0], count: count) }, sampleRate: rate)
                read += Double(count) / rate
                // Answer "Keep recording" each time, to find every place it would ask.
                if detector.machineStopped {
                    asked.append(String(format: "%.0f s", read))
                    detector.dismiss()
                }
            }
            print(String(format: "STOPCHECK %@  %.0f s long  asked at: %@", path, read, asked.isEmpty ? "never" : asked.joined(separator: ", ")))
        }
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

    /// Side B was spoiled and recorded again as C, then B was deleted and C renamed.
    /// The next side is C again, in a file of its own.
    @Test func aSideAfterARenameNeverReusesAFile() async throws {
        let a = try await library.beginCapture(machine: nil, title: "T", speed: nil)
        try writeAudio(to: a.url)
        try await library.finishCapture(sourceID: a.sourceID)
        let b = try await library.beginNextSide(tapeID: a.tapeID)
        try writeAudio(to: b.url, seconds: 2)
        try await library.finishCapture(sourceID: b.sourceID)
        let c = try await library.beginNextSide(tapeID: a.tapeID)
        try writeAudio(to: c.url, seconds: 3)
        try await library.finishCapture(sourceID: c.sourceID)

        try await library.removeSide(sourceID: b.sourceID) { try FileManager.default.removeItem(at: $0) }
        try await library.renameSide(sourceID: c.sourceID, to: "B")
        #expect(try await library.nextSide(tapeID: a.tapeID) == "C")

        let next = try await library.beginNextSide(tapeID: a.tapeID)
        #expect(next.side == "C")
        #expect(next.url.lastPathComponent == "side-c-2.caf")
        #expect(FileManager.default.fileExists(atPath: c.url.path), "the renamed side's master is untouched")
        try writeAudio(to: next.url)
        try await library.finishCapture(sourceID: next.sourceID)

        let shelf = try await database.writer.read { db in try Library.fetchShelf(db) }
        #expect(shelf[0].items.map(\.name) == ["Side A", "Side B", "Side C"])
        #expect(shelf[0].items.map(\.source.position) == [0, 1, 2])
    }

    /// Re-recording the only side so far: it's removed, then recorded again as A.
    @Test func theOnlySideCanBeRecordedAgain() async throws {
        let first = try await library.beginCapture(machine: nil, title: "T", speed: nil)
        try writeAudio(to: first.url)
        try await library.finishCapture(sourceID: first.sourceID)

        await #expect(throws: SideError.lastSide) {
            try await library.removeSide(sourceID: first.sourceID)
        }
        try await library.removeSide(sourceID: first.sourceID, allowingLast: true) { try FileManager.default.removeItem(at: $0) }
        let again = try await library.beginNextSide(tapeID: first.tapeID)
        try writeAudio(to: again.url)
        try await library.finishCapture(sourceID: again.sourceID)

        #expect(again.side == "A")
        let shelf = try await database.writer.read { db in try Library.fetchShelf(db) }
        #expect(shelf.count == 1)
        #expect(shelf[0].items.map(\.name) == ["Side A"])
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
