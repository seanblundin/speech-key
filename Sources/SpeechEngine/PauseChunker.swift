import Foundation
import FluidAudio

/// Cuts a live 16 kHz mono stream into chunks at natural pauses, using Silero VAD.
///
/// Parakeet works in 15-second windows, so chunks aim to end at a pause before 15 s.
/// Feed audio with `append` as it arrives; call `flush` when the stream stops or when a
/// caller needs everything so far (a dictation key release, a meeting Snapshot).
///
/// Not thread-safe: use one chunker per stream, from one task.
public final class PauseChunker {
    public struct Chunk: Sendable {
        public let samples: [Float]
        /// Seconds from the start of the stream.
        public let start: TimeInterval
        public var duration: TimeInterval { Double(samples.count) / Double(SpeechEngine.sampleRate) }
        /// False when VAD heard no speech at all, so callers can skip it.
        public let hasSpeech: Bool
    }

    public struct Config: Sendable {
        /// Don't cut before this much audio, unless flushing.
        public var minChunk: TimeInterval = 4
        /// Always cut by here, at the quietest recent moment if no pause came.
        public var maxChunk: TimeInterval = 14.5
        /// A pause this long counts as a cut point.
        public var minPause: TimeInterval = 0.35
        /// VAD probability above which a hop counts as speech.
        public var speechThreshold: Float = 0.5
        public init() {}
    }

    private let vad: VadManager
    private let config: Config
    private var state: VadStreamState
    private var pending: [Float] = []         // not yet run through VAD (less than one hop)
    private var buffer: [Float] = []          // current chunk's audio
    private var hopProbabilities: [Float] = [] // one per VAD hop in `buffer`
    private var bufferStart: Int = 0          // stream sample index of buffer[0]
    private var quietRun: Int = 0             // consecutive quiet hops at the end of buffer
    private var cutCount = 0                  // bumped on every cut, to spot a flush during append

    static let hop = VadManager.chunkSize     // 4096 samples = 256 ms

    init(vad: VadManager, config: Config = Config()) async {
        self.vad = vad
        self.config = config
        self.state = await vad.makeStreamState()
    }

    /// A chunker backed by a shared Silero VAD model (downloaded on first use, loaded once per process).
    public static func make(config: Config = Config()) async throws -> PauseChunker {
        await PauseChunker(vad: try await VADCache.shared.manager(), config: config)
    }

    /// Adds audio; returns any chunks that closed.
    public func append(_ samples: [Float]) async throws -> [Chunk] {
        pending.append(contentsOf: samples)
        var closed: [Chunk] = []
        while pending.count >= Self.hop {
            let hopSamples = Array(pending.prefix(Self.hop))
            pending.removeFirst(Self.hop)
            // Into the buffer before the VAD call, so a flush() during the await (a meeting
            // snapshot) still gets this audio, in order.
            buffer.append(contentsOf: hopSamples)
            let generation = cutCount
            let result = try await vad.processStreamingChunk(hopSamples, state: state)
            state = result.state
            guard generation == cutCount else { continue }   // flushed meanwhile: this hop is gone
            hopProbabilities.append(result.probability)
            quietRun = result.probability < config.speechThreshold ? quietRun + 1 : 0

            let seconds = Double(buffer.count) / Double(SpeechEngine.sampleRate)
            let pauseHops = Int((config.minPause * Double(SpeechEngine.sampleRate) / Double(Self.hop)).rounded(.up))
            if seconds >= config.minChunk, quietRun >= pauseHops {
                closed.append(cut(at: buffer.count))
            } else if seconds >= config.maxChunk {
                closed.append(cut(at: quietestCutPoint()))
            }
        }
        return closed
    }

    /// Returns everything buffered so far as one chunk (nil if there is nothing).
    public func flush() -> Chunk? {
        buffer.append(contentsOf: pending)
        pending.removeAll()
        guard !buffer.isEmpty else { return nil }
        return cut(at: buffer.count)
    }

    /// Splits off buffer[0..<end] as a chunk and keeps the rest.
    private func cut(at end: Int) -> Chunk {
        let hopsUsed = min(hopProbabilities.count, end / Self.hop)
        let hasSpeech = hopProbabilities.prefix(max(hopsUsed, 1)).contains { $0 >= config.speechThreshold }
            || (hopProbabilities.isEmpty && !buffer.isEmpty)
        let chunk = Chunk(samples: Array(buffer[..<end]),
                          start: Double(bufferStart) / Double(SpeechEngine.sampleRate),
                          hasSpeech: hasSpeech)
        buffer.removeFirst(end)
        hopProbabilities.removeFirst(hopsUsed)
        bufferStart += end
        quietRun = 0
        cutCount += 1
        return chunk
    }

    /// The end of the quietest hop in the last few seconds, so a forced cut lands between words.
    private func quietestCutPoint() -> Int {
        let lookback = min(hopProbabilities.count, Int(3.0 * Double(SpeechEngine.sampleRate) / Double(Self.hop)))
        guard lookback > 0 else { return buffer.count }
        let startHop = hopProbabilities.count - lookback
        var best = startHop
        for i in startHop..<hopProbabilities.count where hopProbabilities[i] < hopProbabilities[best] { best = i }
        // A hop is 256 ms, long enough to land mid-word. Refine to the quietest 20 ms inside it.
        let lo = max(0, best * Self.hop - Self.hop / 2)
        let hi = min(buffer.count, (best + 1) * Self.hop + Self.hop / 2)
        let window = SpeechEngine.sampleRate / 50
        var bestStart = lo
        var bestEnergy = Float.greatestFiniteMagnitude
        var start = lo
        while start + window <= hi {
            var e: Float = 0
            for k in start..<(start + window) { e += buffer[k] * buffer[k] }
            if e < bestEnergy { bestEnergy = e; bestStart = start }
            start += window / 2
        }
        return min(buffer.count, max(1, bestStart + window / 2))
    }
}

/// Loads Silero VAD once and shares it between chunkers (it is an actor, so sharing is safe).
actor VADCache {
    static let shared = VADCache()
    private var cached: VadManager?
    private var loading: Task<VadManager, Error>?

    func manager() async throws -> VadManager {
        if let cached { return cached }
        if let loading { return try await loading.value }
        let task = Task { () throws -> VadManager in
            let vad = try await VadManager()
            // The voice detector only decides where pauses are, so it's checked right after loading.
            try ModelIntegrity.verify(AsrModels.defaultCacheDirectory().deletingLastPathComponent().appendingPathComponent("silero-vad"))
            return vad
        }
        loading = task
        do {
            let m = try await task.value
            cached = m
            loading = nil
            return m
        } catch {
            loading = nil
            throw error
        }
    }
}
