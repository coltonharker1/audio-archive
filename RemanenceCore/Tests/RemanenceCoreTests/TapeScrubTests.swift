import AVFoundation
import Foundation
import Testing
@testable import RemanenceCore

@Suite struct TapeScrubTests {
    let rate = 48000.0

    /// Ten seconds of a steady 1 kHz tone.
    private func tone() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tape-scrub-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(rate * 10)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = 0.5 * sin(2 * .pi * 1000 * Float(index) / Float(rate))
        }
        try file.write(from: buffer)
        return url
    }

    private func generator(_ url: URL) throws -> TapeGenerator {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        return TapeGenerator(file: file, node: AVAudioPlayerNode())
    }

    private func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count)))
    }

    @Test func aSteadyDragPlaysAtNormalSpeedAndLevel() throws {
        let tape = try generator(try tone())
        let block = TapeGenerator.blockLength
        var target = 1.0
        var last: AVAudioPCMBuffer?
        // Drag at exactly normal speed for a second.
        for _ in 0..<Int(1 / block) {
            target += block
            last = tape.block(towards: (target) * rate)
        }
        #expect(abs(tape.velocity - 1) < 0.02)
        // Trailing the pointer a little, as a reel with weight would.
        let lag = target - tape.head! / rate
        #expect(lag > 0 && lag < 0.15)
        #expect(abs(loudness(try #require(last)) - Float(0.5 / 2.squareRoot())) < 0.03)
    }

    @Test func lettingGoWindsDownToSilence() throws {
        let tape = try generator(try tone())
        var target = 1.0
        for _ in 0..<40 {
            target += TapeGenerator.blockLength * 2
            _ = tape.block(towards: (target) * rate)
        }
        var last: AVAudioPCMBuffer?
        for _ in 0..<40 { last = tape.block(towards: (target) * rate) }
        #expect(abs(tape.velocity) < TapeGenerator.restSpeed)
        #expect(loudness(try #require(last)) < 0.001)
        // It settled where the pointer stopped, without running past it.
        #expect(abs(tape.head! / rate - target) < 0.005)
    }

    @Test func aFarJumpMovesStraightThere() throws {
        let tape = try generator(try tone())
        _ = tape.block(towards: (1) * rate)
        _ = tape.block(towards: (9) * rate)
        #expect(abs(tape.head! / rate - 9) < 0.001)
        #expect(tape.velocity == 0)
    }

    @Test func draggingBackPlaysBackwards() throws {
        let tape = try generator(try tone())
        var target = 5.0
        for _ in 0..<80 {
            target -= TapeGenerator.blockLength
            _ = tape.block(towards: (target) * rate)
        }
        #expect(abs(tape.velocity + 1) < 0.02)
    }
}
