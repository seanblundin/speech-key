import AVFoundation

/// The "Me" stream: the default microphone, with Apple's voice processing on so laptop-speaker
/// calls don't flood the mic with the other side. Delivers 16 kHz mono Float32.
final class MeetingMic {
    var onSamples: (([Float]) -> Void)?
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private(set) var isRunning = false
    /// Off for now: on macOS it doesn't cancel other apps' audio anyway, and it can deliver silence
    /// on some input formats. The transcript drops mic lines that echo the call instead.
    var voiceProcessing = false
    private(set) var formatDescription = ""

    func start() throws {
        let input = engine.inputNode
        if voiceProcessing {
            try? input.setVoiceProcessingEnabled(true)
            if input.isVoiceProcessingEnabled {
                // Voice processing ducks other apps by default, which would make the call itself quieter.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }
        let format = input.outputFormat(forBus: 0)
        formatDescription = "\(format.sampleRate) Hz, \(format.channelCount) ch, voice processing \(input.isVoiceProcessingEnabled)"
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorder.RecorderError.noInput }
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in self?.process(buffer) }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
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
        onSamples?(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
    }
}
