import AudioToolbox
import CoreAudio
import Foundation

public struct InputDevice: Identifiable, Hashable, Sendable {
    /// What kind of hardware an input really is.
    public enum Kind: Int, Comparable, Sendable {
        case interface, builtIn, other, virtual

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        init(transport: UInt32) {
            switch transport {
            case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeFireWire,
                 kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI,
                 kAudioDeviceTransportTypeAVB:
                self = .interface
            case kAudioDeviceTransportTypeBuiltIn:
                self = .builtIn
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                 kAudioDeviceTransportTypeAutoAggregate:
                self = .virtual
            default:
                self = .other
            }
        }
    }

    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let channels: Int
    public let kind: Kind

    /// Real interfaces come first and virtual devices last. Apps like Teams install
    /// silent virtual inputs, and choosing one would look like a dead meter.
    static func ordered(_ devices: [InputDevice]) -> [InputDevice] {
        devices.enumerated()
            .sorted { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }
            .map(\.element)
    }
}

/// Which of an interface's inputs to record.
public enum ChannelMode: String, CaseIterable, Sendable {
    case first, second, stereo

    public var label: String {
        switch self {
        case .first: "Input 1"
        case .second: "Input 2"
        case .stereo: "Stereo (1 + 2)"
        }
    }

    func indices(available: Int) -> [Int] {
        switch self {
        case .first: [0]
        case .second: available > 1 ? [1] : [0]
        case .stereo: available > 1 ? [0, 1] : [0]
        }
    }
}

public enum CaptureError: LocalizedError {
    case noInput
    case couldNotUseDevice(String)

    public var errorDescription: String? {
        switch self {
        case .noInput: "That input isn’t giving any audio."
        case .couldNotUseDevice(let name): "\(name) couldn’t be used."
        }
    }
}

/// A moment's reading from the input, safe to read from anywhere.
public struct CaptureSnapshot: Sendable {
    public var vu: Double = -38
    public var peak: Double = -140
    public var recentPeak: Double = -140
    public var clippedRecently = false
    public var advice = LevelAdvice.noSignal
    public var channelFinding = ChannelCheck.Finding.notEnoughSound
    public var seconds: Double = 0
    public var isRecording = false
    public var dropouts = 0
    public var tapeLooksFinished = false
    public var failure: String?
    public var sampleRate: Double = 0
    /// The peak light. It stays lit for a couple of seconds after a peak near full
    /// scale, because a sharp peak can clip while the slow needle looks fine.
    public var peakLit = false
    /// How many blocks of audio have arrived. If this stays at zero, the input isn't
    /// delivering anything, which looks just like silence unless it's checked.
    public var buffersReceived = 0
}

/// Listens to an input, reports its levels, and writes it to a capture file.
///
/// Audio arrives on a real-time thread, and file writes happen on their own queue,
/// so a slow disk can't hold up the audio. The signal is written exactly as it
/// arrives. Nothing here changes its gain.
public final class AudioCapture: @unchecked Sendable {
    public var onInterrupted: (@Sendable (String) -> Void)?
    /// The input changed while only listening, so it needs starting again or the meter
    /// would just sit there looking like silence.
    public var onInputChanged: (@Sendable () -> Void)?

    /// An input-only audio unit, created on every start. It's used directly rather
    /// than through AVAudioEngine, which keeps the first sample rate it sees for the
    /// life of the app and resamples to it, and which stops itself when pointed at an
    /// input-only device.
    private var unit: AudioUnit?
    private var renderList: UnsafeMutableAudioBufferListPointer?
    private var renderChannels: [UnsafeMutablePointer<Float>] = []
    private var renderCapacity: UInt32 = 0
    private var renderRate: Double = 0
    private var deviceListeners: [(device: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    /// Audio arrives on a real-time thread that mustn't wait, so the work happens here.
    private let processQueue = DispatchQueue(label: "com.colton.remanence.capture.process", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "com.colton.remanence.capture.device")
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.colton.remanence.capture", qos: .userInteractive)

    private var state = CaptureSnapshot()
    private var meter = VUBallistics()
    private var recent = RecentPeaks(seconds: 30)
    private var channelCheck = ChannelCheck()
    private var endDetector = TapeEndDetector()
    private var indices: [Int] = [0]
    private var file: CaptureFile?
    private var expectedSampleTime: Double?
    private var meterPeak: Double = -140
    private var meterPeakSeconds = 0.0
    private var restoreRate: (device: AudioDeviceID, rate: Double)?
    private var activity: NSObjectProtocol?
    private var peakLightSeconds = 0.0

    public init() {}

    deinit { stopUnit() }

    public var snapshot: CaptureSnapshot {
        lock.withLock { state }
    }

    // MARK: Devices

    public static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        let devices = ids.compactMap { id -> InputDevice? in
            let channels = inputChannelCount(id)
            guard channels > 0,
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return InputDevice(id: id, uid: uid, name: name, channels: channels, kind: .init(transport: transportType(id)))
        }
        return InputDevice.ordered(devices)
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Picks the device's highest rate up to 96 kHz, the archival standard, and
    /// remembers the old one to put back afterward.
    private func preferHighestRate(on device: AudioDeviceID) {
        // Another app may be using this device, like a call on the built-in mic.
        // Changing its rate could disturb that app's audio, so it's left alone.
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inUse: UInt32 = 0
        var inUseSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &inUseSize, &inUse)
        guard inUse == 0 else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges) == noErr else { return }

        let best = ranges.map { min($0.mMaximum, 96000) }.filter { $0 <= 96000 }.max()
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        var current = 0.0
        size = UInt32(MemoryLayout<Double>.size)
        guard let best, AudioObjectGetPropertyData(device, &address, 0, nil, &size, &current) == noErr, current != best else { return }

        var target = best
        guard AudioObjectSetPropertyData(device, &address, 0, nil, size, &target) == noErr else { return }
        restoreRate = (device, current)

        // The change happens a moment later, and capture should start at the new rate.
        for _ in 0..<100 {
            var now = 0.0
            size = UInt32(MemoryLayout<Double>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &now) == noErr, now == best { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func restorePreviousRate() {
        guard let restore = restoreRate else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = restore.rate
        AudioObjectSetPropertyData(restore.device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &rate)
        restoreRate = nil
    }

    private static func nominalRate(of device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    // MARK: Listening

    /// Starts listening, without saving anything, so the meter is live during setup.
    public func start(device: InputDevice, mode: ChannelMode) throws {
        stopUnit()
        // A restart on the same device keeps its rate. Putting it back here would
        // change the device again, which triggers another restart, and so on forever.
        if restoreRate?.device != device.id { restorePreviousRate() }
        lock.withLock {
            state = CaptureSnapshot()
            meter = VUBallistics()
            recent = RecentPeaks(seconds: 30)
            channelCheck = ChannelCheck()
            indices = mode.indices(available: device.channels)
            meterPeak = -140
            meterPeakSeconds = 0
        }

        preferHighestRate(on: device.id)

        let (newUnit, hardware) = try makeUnit(for: device)
        do {
            try prepare(newUnit, hardware: hardware, deviceName: device.name)
        } catch {
            stopUnit()
            throw error
        }
        lock.withLock { state.sampleRate = hardware.mSampleRate }
        listenForChanges(on: device.id)
    }

    /// Creates a unit that only captures, on the chosen device, once the device's
    /// new rate has reached it.
    private func makeUnit(for device: InputDevice) throws -> (AudioUnit, AudioStreamBasicDescription) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.couldNotUseDevice(device.name)
        }
        let deviceRate = Self.nominalRate(of: device.id)

        for attempt in 0..<20 {
            var created: AudioUnit?
            guard AudioComponentInstanceNew(component, &created) == noErr, let created else {
                throw CaptureError.couldNotUseDevice(device.name)
            }
            var on: UInt32 = 1
            var off: UInt32 = 0
            var deviceID = device.id
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let uintSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, uintSize) == noErr,
                  AudioUnitSetProperty(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, uintSize) == noErr,
                  AudioUnitSetProperty(created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr,
                  AudioUnitGetProperty(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size) == noErr else {
                AudioComponentInstanceDispose(created)
                throw CaptureError.couldNotUseDevice(device.name)
            }
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else {
                AudioComponentInstanceDispose(created)
                throw CaptureError.noInput
            }
            if deviceRate == nil || hardware.mSampleRate == deviceRate || attempt == 19 {
                return (created, hardware)
            }
            AudioComponentInstanceDispose(created)
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw CaptureError.couldNotUseDevice(device.name)
    }

    /// Asks for the hardware's own rate and channels, so nothing gets converted.
    private func prepare(_ newUnit: AudioUnit, hardware: AudioStreamBasicDescription, deviceName: String) throws {
        unit = newUnit
        var client = AudioStreamBasicDescription(
            mSampleRate: hardware.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: hardware.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var maxFrames: UInt32 = 0
        var maxSize = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(newUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &maxSize)
        renderCapacity = max(maxFrames, 8192)
        renderRate = hardware.mSampleRate

        let channels = Int(hardware.mChannelsPerFrame)
        renderChannels = (0..<channels).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: Int(renderCapacity))
            pointer.initialize(repeating: 0, count: Int(renderCapacity))
            return pointer
        }
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        renderList = list

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, _, frames, _ in
                Unmanaged<AudioCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        guard AudioUnitSetProperty(newUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr,
              AudioUnitSetProperty(newUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(newUnit) == noErr,
              AudioOutputUnitStart(newUnit) == noErr else {
            throw CaptureError.couldNotUseDevice(deviceName)
        }
    }

    /// A device being unplugged, or another app changing its rate, arrives here.
    private func listenForChanges(on device: AudioObjectID) {
        for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleInterruption("The audio interface changed or was disconnected.")
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block) == noErr {
                deviceListeners.append((device, address, block))
            }
        }
    }

    /// Whether audio is really flowing, rather than just having been asked to.
    public var isRunning: Bool {
        guard let unit else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
        return running != 0
    }

    public func setMode(_ mode: ChannelMode, device: InputDevice) {
        lock.withLock {
            indices = mode.indices(available: device.channels)
            channelCheck = ChannelCheck()
        }
    }

    public func resetChannelCheck() {
        lock.withLock { channelCheck = ChannelCheck() }
    }

    /// Stops listening. Any recording is closed properly first.
    public func stop() {
        stopUnit()
        restorePreviousRate()
    }

    private func stopUnit() {
        stopRecording()
        for listener in deviceListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.device, &address, listenerQueue, listener.block)
        }
        deviceListeners = []
        if let unit {
            // Once this returns, the audio thread has finished with the buffers.
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        processQueue.sync {}
        renderChannels.forEach { $0.deallocate() }
        renderChannels = []
        renderList?.unsafeMutablePointer.deallocate()
        renderList = nil
    }

    // MARK: Recording

    public func startRecording(to url: URL) throws {
        let (rate, channels) = lock.withLock { (state.sampleRate, indices.count) }
        let capture = try CaptureFile(url: url, sampleRate: rate, channels: channels)

        // Keeps the Mac from idle-sleeping and tells macOS this is time-critical.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Recording a tape"
        )
        lock.withLock {
            file = capture
            expectedSampleTime = nil
            endDetector = TapeEndDetector()
            state.seconds = 0
            state.dropouts = 0
            state.tapeLooksFinished = false
            state.failure = nil
            state.isRecording = true
        }
    }

    /// Closes the file, waiting for every buffered write to finish first.
    public func stopRecording() {
        processQueue.sync {}
        let closing: CaptureFile? = lock.withLock {
            let current = file
            file = nil
            state.isRecording = false
            return current
        }
        guard let closing else { return }
        writeQueue.sync {
            try? closing.close()
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// "Keep recording" after the question about the tape ending.
    public func dismissTapeEnd() {
        lock.withLock {
            endDetector.dismiss()
            state.tapeLooksFinished = false
        }
    }

    private func handleInterruption(_ reason: String) {
        let wasRecording = lock.withLock { state.isRecording }
        lock.withLock { state.failure = reason }
        guard wasRecording else {
            onInputChanged?()
            return
        }
        stopRecording()
        onInterrupted?(reason)
    }

    // MARK: The audio thread

    /// Runs on the real-time thread, so it only collects the audio and hands it on.
    private func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timeStamp: UnsafePointer<AudioTimeStamp>,
        _ frames: UInt32
    ) -> OSStatus {
        guard let unit, let list = renderList, frames <= renderCapacity else { return noErr }
        let byteCount = frames * UInt32(MemoryLayout<Float>.size)
        for index in renderChannels.indices {
            list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: renderChannels[index])
        }
        let status = AudioUnitRender(unit, flags, timeStamp, 1, frames, list.unsafeMutablePointer)
        guard status == noErr else { return status }

        let copies = renderChannels.map { source -> UnsafeMutableBufferPointer<Float> in
            let copy = UnsafeMutableBufferPointer<Float>.allocate(capacity: Int(frames))
            _ = copy.initialize(from: UnsafeBufferPointer(start: source, count: Int(frames)))
            return copy
        }
        let stamp = timeStamp.pointee
        let sampleTime = stamp.mFlags.contains(.sampleTimeValid) ? stamp.mSampleTime : nil
        let rate = renderRate
        processQueue.async { [self] in
            process(copies, sampleRate: rate, sampleTime: sampleTime)
            copies.forEach { $0.deallocate() }
        }
        return noErr
    }

    private func process(_ channels: [UnsafeMutableBufferPointer<Float>], sampleRate: Double, sampleTime: Double?) {
        guard let frames = channels.first?.count, frames > 0 else { return }
        let available = channels.count

        let (selected, recording): ([Int], CaptureFile?) = lock.withLock {
            (indices.filter { $0 < available }, file)
        }
        guard let first = selected.first else { return }

        let blockSeconds = Double(frames) / sampleRate
        let levels = BlockLevels(samples: UnsafeBufferPointer(channels[first]))

        var payload: Data?
        if recording != nil {
            payload = CaptureFile.interleave(selected.map { UnsafePointer(channels[$0].baseAddress!) }, frames: frames)
        }

        lock.withLock {
            state.buffersReceived += 1
            meter.update(rms: levels.rms, seconds: blockSeconds)
            recent.add(peak: levels.peak, clipped: levels.clipped, seconds: blockSeconds)
            if available > 1 {
                channelCheck.add(
                    UnsafeBufferPointer(channels[0]),
                    UnsafeBufferPointer(channels[1])
                )
            }
            peakLightSeconds = levels.peak > -3 || levels.clipped ? 2 : max(0, peakLightSeconds - blockSeconds)
            state.peakLit = peakLightSeconds > 0
            state.vu = meter.vu
            // Hardware blocks can be very short, so the reading covers a tenth of a
            // second, or the screen would miss peaks between its redraws.
            meterPeak = max(meterPeak, levels.peak)
            meterPeakSeconds += blockSeconds
            if meterPeakSeconds >= 0.1 {
                state.peak = meterPeak
                meterPeak = -140
                meterPeakSeconds = 0
            }
            state.recentPeak = recent.peak
            state.clippedRecently = recent.clipped
            state.advice = recent.advice
            state.channelFinding = channelCheck.finding

            if recording != nil {
                // A gap in the hardware's clock means audio was lost before reaching here.
                if let sampleTime {
                    if let expected = expectedSampleTime, abs(sampleTime - expected) > Double(frames) / 2 {
                        state.dropouts += 1
                    }
                    expectedSampleTime = sampleTime + Double(frames)
                }
                state.seconds += blockSeconds
                endDetector.noteSoundIfReturned()
                if endDetector.add(rms: levels.rms, seconds: blockSeconds) {
                    state.tapeLooksFinished = true
                }
            }
        }

        if let recording, let payload {
            writeQueue.async { [weak self] in
                do {
                    try recording.append(payload, frames: frames)
                } catch {
                    self?.handleWriteFailure(error)
                }
            }
        }
    }

    private func handleWriteFailure(_ error: Error) {
        let reason = "Writing the recording failed. \(error.localizedDescription)"
        lock.withLock { state.failure = reason; file = nil; state.isRecording = false }
        onInterrupted?(reason)
    }

    /// How many hours of this format fit in the free space, for an early warning.
    public static func hoursAvailable(on url: URL, sampleRate: Double, channels: Int) -> Double? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        let perHour = sampleRate * Double(CaptureFile.bytesPerSample * channels) * 3600
        return perHour > 0 ? Double(free) / perHour : nil
    }
}
