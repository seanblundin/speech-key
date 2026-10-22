import AVFoundation
import CoreAudio

/// Records the microphone as 16 kHz mono Float32, the format the engine wants.
///
/// Prefers the built-in microphone, because AirPods drop into low-quality call mode
/// (and take a second or two to switch) whenever their mic is opened.
///
/// Opening the mic can take a while (hundreds of milliseconds, seconds with some devices), so it
/// happens on a private queue and never on the main thread: the key tap and the pill stay
/// responsive however slow the audio hardware is (2026-10-21: holding fn sometimes showed the pill
/// only after ~5 s, and fast repeated taps stalled it for longer). The mic also stays open for a
/// moment after each recording, so a quick next press doesn't have to reopen it.
final class AudioRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "speechkey.recorder", qos: .userInteractive)
    /// Audio buffers arrive here. Separate from `queue`, which stops the AudioQueue synchronously
    /// and would otherwise wait on its own callbacks.
    private let audioCallbacks = DispatchQueue(label: "speechkey.recorder.audio", qos: .userInteractive)
    /// How long the mic stays open after a recording ends, in case another press follows.
    static let closeDelay: TimeInterval = 1.5

    // Touched only on `queue`.
    private var engine: AVAudioEngine?
    private var audioQueue: AudioQueueRef?
    /// The next recording's queue, created ahead of time (creating one can take ~0.2 s).
    private var spare: AudioQueueRef?
    private var closeWork: DispatchWorkItem?
    private var isOpen: Bool { engine != nil || audioQueue != nil }

    // Shared with the audio thread, under `lock`.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var capturing = false
    private var samples: [Float] = []
    private var onSamples: (([Float]) -> Void)?
    private var onLevel: ((Float) -> Void)?

    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    var preferBuiltInMic = true
    /// Tests print how long each step of opening the mic takes.
    nonisolated(unsafe) static var traceTiming = false

    /// Starts a recording into a fresh buffer. Returns at once; the mic opens on the recorder's queue
    /// if it isn't open already. `samples` gets each converted buffer (on the audio thread), `level`
    /// the loudness 0…1 (on main), and `opened` runs on main with an error or how long opening took.
    func begin(samples: @escaping ([Float]) -> Void, level: @escaping (Float) -> Void,
               opened: @escaping (Error?, TimeInterval) -> Void) {
        lock.withLock {
            self.samples.removeAll(keepingCapacity: true)
            onSamples = samples
            onLevel = level
            capturing = true
        }
        queue.async { [self] in
            closeWork?.cancel(); closeWork = nil
            let t0 = Date()
            var failure: Error?
            if !isOpen {
                do { try open() } catch {
                    failure = error
                    lock.withLock { capturing = false; onSamples = nil; onLevel = nil }
                }
            }
            let took = Date().timeIntervalSince(t0)
            DispatchQueue.main.async { opened(failure, took) }
        }
    }

    /// Ends the recording and returns everything captured since `begin`. Cheap: the mic itself
    /// closes a moment later on the recorder's queue, unless another recording begins first.
    @discardableResult
    func end() -> [Float] {
        let out: [Float] = lock.withLock {
            capturing = false
            onSamples = nil
            onLevel = nil
            let s = samples
            samples = []
            return s
        }
        queue.async { [self] in
            closeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.close() }
            closeWork = work
            queue.asyncAfter(deadline: .now() + Self.closeDelay, execute: work)
        }
        return out
    }

    /// Gets the first recording's queue ready ahead of time.
    func prewarm() {
        queue.async { [self] in if spare == nil { spare = try? makeQueue() } }
    }

    // MARK: - Engine (recorder queue)

    /// Opens the mic. An input-only AudioQueue first: it opens in tens of milliseconds, where
    /// AVAudioEngine also sets up the speakers and took 1–2 s on Sean's Mac (2026-10-21), long
    /// enough that a short press recorded nothing. AVAudioEngine stays as the fallback.
    private func open() throws {
        do {
            try openQueue()
        } catch {
            UtterLog.write("audio queue failed (\(error)); using AVAudioEngine")
            try openEngine()
        }
    }

    private func openQueue() throws {
        let t0 = Date()
        let aq = try spare ?? makeQueue()
        spare = nil
        let t1 = Date()
        let status = AudioQueueStart(aq, nil)
        guard status == noErr else { AudioQueueDispose(aq, true); throw RecorderError.queue(status) }
        audioQueue = aq
        if Self.traceTiming {
            print(String(format: "  queue ready %.3f, start %.3f", t1.timeIntervalSince(t0), Date().timeIntervalSince(t1)))
        }
    }

    /// A stopped input queue on the preferred mic, with its buffers queued. Stopped queues don't
    /// use the mic, so keeping one ready doesn't light the mic indicator.
    private func makeQueue() throws -> AudioQueueRef {
        var format = AudioStreamBasicDescription(
            mSampleRate: target.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        var aq: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&aq, &format, 0, audioCallbacks) { [weak self] aq, buffer, _, _, _ in
            let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
            if count > 0 {
                let floats = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
                self?.deliver(Array(UnsafeBufferPointer(start: floats, count: count)))
            }
            AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
        }
        guard status == noErr, let aq else { throw RecorderError.queue(status) }
        if preferBuiltInMic, let device = Self.builtInMicrophone(), var uid = Self.uid(of: device) {
            AudioQueueSetProperty(aq, kAudioQueueProperty_CurrentDevice, &uid, UInt32(MemoryLayout<CFString>.size))
        }
        // ~50 ms buffers: the pill's bars stay lively and nothing waits long for audio.
        let bytes = UInt32(target.sampleRate * 0.05) * 4
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(aq, bytes, &buffer) == noErr, let buffer { AudioQueueEnqueueBuffer(aq, buffer, 0, nil) }
        }
        return aq
    }

    private func openEngine() throws {
        let engine = AVAudioEngine()   // a fresh engine each time the mic opens, so device changes are picked up
        let input = engine.inputNode
        if preferBuiltInMic, let device = Self.builtInMicrophone(), let unit = input.audioUnit {
            var id = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        let conv = AVAudioConverter(from: format, to: target)
        lock.withLock { converter = conv }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    private func close() {
        // Still recording? (A recording began after this close was scheduled.)
        if lock.withLock({ capturing }) { return }
        if let audioQueue {
            AudioQueueStop(audioQueue, true)
            AudioQueueDispose(audioQueue, true)
            self.audioQueue = nil
            if spare == nil { spare = try? makeQueue() }
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
    }

    // MARK: - Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        let (conv, active) = lock.withLock { (converter, capturing) }
        guard active, let conv else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData, out.frameLength > 0 else { return }
        deliver(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
    }

    /// 16 kHz mono samples from either input path.
    private func deliver(_ chunk: [Float]) {
        let (sink, levelSink): ((([Float]) -> Void)?, ((Float) -> Void)?) = lock.withLock {
            guard capturing else { return (nil, nil) }
            samples.append(contentsOf: chunk)
            return (onSamples, onLevel)
        }
        guard let sink else { return }
        sink(chunk)

        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = (sum / Float(chunk.count)).squareRoot()
        // Speech RMS sits around 0.01–0.2; map to 0…1 on a log-ish curve so quiet talk still moves the bars.
        let level = min(1, max(0, (20 * log10(max(rms, 1e-5)) + 55) / 40))
        if let levelSink { DispatchQueue.main.async { levelSink(level) } }
    }

    enum RecorderError: LocalizedError {
        case noInput
        case queue(OSStatus)
        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone input is available."
            case .queue(let status): return "The audio queue failed (\(status))."
            }
        }
    }

    static func uid(of device: AudioDeviceID) -> CFString? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue()
    }

    /// The Mac's own microphone, if it has one.
    static func builtInMicrophone() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }

        for device in devices {
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &tAddr, 0, nil, &tSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioObjectPropertyScopeInput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(device, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 {
                return device
            }
        }
        return nil
    }
}
