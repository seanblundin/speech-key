import Foundation
import FluidAudio

/// One stretch of one voice. Times are seconds from the start of the audio.
public struct VoiceTurn: Sendable, Equatable {
    public let voice: String
    public let start: TimeInterval
    public let end: TimeInterval
    public init(voice: String, start: TimeInterval, end: TimeInterval) {
        self.voice = voice; self.start = start; self.end = end
    }
}

/// Who spoke when in a recording, plus a fingerprint of each voice (256 numbers, unit length).
public struct VoiceSplit: Sendable {
    public let turns: [VoiceTurn]
    public let prints: [String: [Float]]
    /// Seconds each voice spoke.
    public var seconds: [String: TimeInterval] {
        var out: [String: TimeInterval] = [:]
        for t in turns { out[t.voice, default: 0] += t.end - t.start }
        return out
    }
}

/// Tells the voices in a recording apart, on this Mac: FluidAudio's batch pipeline (pyannote
/// segmentation, WeSpeaker voice fingerprints, VBx clustering). Measured on Sean's M2 Air,
/// 2026-11-26: a real 17.5-minute meeting of four people took 4.6 s, found all four, and gave
/// 83.5% of the words to the right person (3% to nobody, 13% to the wrong one, mostly where
/// people talk over each other).
///
/// The models (34 MB) download on first use. They aren't in `ModelManifest`: a changed one could
/// only mislabel a voice, never put words in a transcript.
public actor SpeakerSplitter {
    public static let shared = SpeakerSplitter()
    private var manager: OfflineDiarizerManager?

    private func ready() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let m = OfflineDiarizerManager()
        try await m.prepareModels()
        manager = m
        return m
    }

    private var printer: DiarizerManager?

    /// The fingerprint of whoever is speaking in a short stretch of 16 kHz mono audio (up to 10 s),
    /// assuming it is one person.
    public func fingerprint(_ samples: [Float]) async throws -> [Float] {
        if printer == nil {
            let m = DiarizerManager()
            m.initialize(models: try await DiarizerModels.downloadIfNeeded())
            printer = m
        }
        return try printer!.extractSpeakerEmbedding(from: Array(samples.prefix(160_000)))
    }

    /// Splits an audio file (any format AVFoundation reads).
    public func split(file: URL) async throws -> VoiceSplit {
        Self.result(try await ready().process(file))
    }

    /// Splits 16 kHz mono samples.
    public func split(samples: [Float]) async throws -> VoiceSplit {
        Self.result(try await ready().process(audio: samples))
    }

    private static func result(_ r: DiarizationResult) -> VoiceSplit {
        let turns = r.segments.map { VoiceTurn(voice: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        // A voice's fingerprint: its turns' fingerprints averaged, longer turns counting more.
        var sums: [String: [Float]] = [:]
        for s in r.segments where !s.embedding.isEmpty {
            let w = max(0.1, s.durationSeconds)
            var sum = sums[s.speakerId] ?? [Float](repeating: 0, count: s.embedding.count)
            guard sum.count == s.embedding.count else { continue }
            for i in sum.indices { sum[i] += s.embedding[i] * w }
            sums[s.speakerId] = sum
        }
        return VoiceSplit(turns: turns, prints: sums.mapValues(VoiceLabels.unit))
    }
}
