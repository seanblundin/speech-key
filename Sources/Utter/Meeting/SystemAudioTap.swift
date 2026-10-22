import AVFoundation
import CoreAudio

/// Captures everything the Mac plays (Zoom, Teams, FaceTime, browsers), minus Utter itself,
/// with a Core Audio process tap (macOS 14.2+). Delivers 16 kHz mono Float32.
///
/// Global rather than per-app, because FaceTime's call audio is played by a system process
/// (avconferenced) that a per-app tap never sees. Notification sounds can get in; that's the cost.
///
/// Gotchas (from MEETING-MODE.md research):
/// - Info.plist needs NSAudioCaptureUsageDescription, or the tap silently delivers zeros.
/// - The permission prompt appears at AudioDeviceStart, not at tap creation.
/// - The aggregate device is hosted on the built-in output, which keeps a steady clock when
///   AirPods connect or disconnect.
final class SystemAudioTap {
    var onSamples: (([Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "utter.systemtap", qos: .userInitiated)
    private(set) var isRunning = false
    /// True once any non-zero sample has arrived (a hint that permission was granted).
    private(set) var heardAnything = false
    private(set) var formatDescription = ""

    enum TapError: LocalizedError {
        case status(String, OSStatus)
        var errorDescription: String? {
            switch self { case .status(let what, let s): return "\(what) failed (\(s))" }
        }
    }

    func start() throws {
        guard !isRunning else { return }
        let excluded = Self.ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Speech Key meeting tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "Creating the audio tap")
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd), "Reading the tap format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw TapError.status("Tap format", -1) }
        inputFormat = format
        converter = AVAudioConverter(from: format, to: target)
        formatDescription = "\(format.sampleRate) Hz, \(format.channelCount) ch, interleaved \(format.isInterleaved), excluding \(excluded.count) process(es)"

        let outputUID = Self.deviceUID(Self.builtInOutput() ?? Self.defaultOutput()) ?? ""
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Speech Key meeting",
            kAudioAggregateDeviceUIDKey: "utter-meeting-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg), "Creating the aggregate device")
        aggregateID = agg

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }, "Creating the audio callback")
        procID = proc
        try check(AudioDeviceStart(aggregateID, procID), "Starting system audio capture")
        isRunning = true
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }

    deinit { stop() }

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        guard let inputFormat, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / inputFormat.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData, out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        if !heardAnything, samples.contains(where: { $0 != 0 }) { heardAnything = true }
        onSamples?(samples)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { stop(); throw TapError.status(what, status) }
    }

    // MARK: - Device lookups

    static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    static func builtInOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        for d in devices {
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(d, &tAddr, 0, nil, &tSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(d, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 { return d }
        }
        return nil
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
