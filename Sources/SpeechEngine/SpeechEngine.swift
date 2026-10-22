import Foundation
import FluidAudio
@_exported import TranscriptText

/// A stretch of transcribed speech. Times are seconds from the start of the audio passed in.
public struct Segment: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
}

/// Which Parakeet weights to run. All share one API and run on the Neural Engine.
public enum EngineModel: String, Sendable, CaseIterable {
    /// Moondream's post-trained v3. FluidAudio's recommendation for new work.
    case ultra
    /// NVIDIA Parakeet TDT 0.6B v3 (25 languages).
    case v3
    /// NVIDIA Parakeet TDT 0.6B v2 (English only).
    case v2

    var fluid: AsrModelVersion {
        switch self {
        case .ultra: return .ultra
        case .v3: return .v3
        case .v2: return .v2
        }
    }
}

/// Who is waiting. Dictation and meeting Snapshots jump ahead of background meeting chunks.
public enum Priority: Int, Sendable, Comparable {
    case background = 0
    case interactive = 1
    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
}

/// The shared speech engine: 16 kHz mono audio in, text out.
///
/// One instance serves every caller. Requests run one at a time, highest priority first,
/// so several streams (dictation, meeting Me, meeting Them) can call it at once without
/// sharing decoder state or deadlocking.
public actor SpeechEngine {
    public static let sampleRate = 16_000
    /// FluidAudio rejects anything shorter.
    public static let minimumSamples = Int(0.3 * Double(sampleRate))

    public let model: EngineModel
    private let asr: AsrManager
    private let ctcModels: CtcModels?
    private var boosting: (key: [Glossary.Term], session: VocabularyBoostingSession)?

    private struct Job {
        let id: UInt64
        let samples: [Float]
        let vocabulary: [Glossary.Term]
        let priority: Priority
        let continuation: CheckedContinuation<[Segment], Error>
    }
    private var queue: [Job] = []
    private var nextID: UInt64 = 0
    private var running = false

    /// Loads (downloading on first use) the Parakeet model and, if `boostNames`, the small CTC
    /// model that checks transcripts against vocabulary terms.
    public init(model: EngineModel = .ultra, boostNames: Bool = true) async throws {
        self.model = model
        let models = try await AsrModels.downloadAndLoad(version: model.fluid)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asr = manager
        self.ctcModels = boostNames ? try await CtcModels.downloadAndLoad() : nil
    }

    /// Transcribe one chunk. `hints` are names to favor (spellings only, no aliases).
    public func transcribe(samples: [Float], hints: [String] = [], priority: Priority = .interactive) async throws -> [Segment] {
        try await transcribe(samples: samples, vocabulary: hints.map { Glossary.Term(canonical: $0, aliases: []) }, priority: priority)
    }

    /// Transcribe one chunk, favoring `vocabulary` terms and the misspellings listed as their aliases.
    public func transcribe(samples: [Float], vocabulary: [Glossary.Term], priority: Priority = .interactive) async throws -> [Segment] {
        guard samples.count >= Self.minimumSamples else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            nextID += 1
            queue.append(Job(id: nextID, samples: samples, vocabulary: vocabulary, priority: priority, continuation: continuation))
            if !running { Task { await self.drain() } }
        }
    }

    /// Reads any audio file as 16 kHz mono Float32.
    public static func loadAudioFile(_ url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }

    /// Convenience: the whole chunk as one string.
    public func text(samples: [Float], vocabulary: [Glossary.Term] = [], priority: Priority = .interactive) async throws -> String {
        try await transcribe(samples: samples, vocabulary: vocabulary, priority: priority).map(\.text).joined(separator: " ")
    }

    // MARK: - Queue

    private func drain() async {
        guard !running else { return }
        running = true
        while let index = nextJobIndex() {
            let job = queue.remove(at: index)
            do {
                job.continuation.resume(returning: try await run(job))
            } catch {
                job.continuation.resume(throwing: error)
            }
        }
        running = false
    }

    /// Highest priority first; first come, first served within a priority.
    private func nextJobIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        var best = 0
        for i in queue.indices.dropFirst() where queue[i].priority > queue[best].priority { best = i }
        return best
    }

    private func run(_ job: Job) async throws -> [Segment] {
        // A fresh decoder state per chunk: chunks are independent and streams never share state.
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(job.samples, decoderState: &state)
        var text = result.text
        let timings = result.tokenTimings ?? []

        if let session = try await boostingSession(for: job.vocabulary), !timings.isEmpty,
           let rescored = await session.rescore(text: text, tokenTimings: timings, audioSamples: job.samples) {
            text = Self.applyNameFixes(rescored.replacements, to: text)
        }
        return Self.segments(text: text, timings: timings, duration: Double(job.samples.count) / Double(Self.sampleRate))
    }

    private func boostingSession(for vocabulary: [Glossary.Term]) async throws -> VocabularyBoostingSession? {
        guard let ctcModels, !vocabulary.isEmpty else { return nil }
        if let boosting, boosting.key == vocabulary { return boosting.session }
        let context = CustomVocabularyContext(terms: vocabulary.map {
            CustomVocabularyTerm(text: $0.canonical, aliases: $0.aliases.isEmpty ? nil : $0.aliases)
        })
        let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels)
        boosting = (vocabulary, session)
        return session
    }

    // MARK: - Name fixes

    /// Applies the boosting pass's suggested swaps to the original transcript.
    ///
    /// FluidAudio can hand back a rebuilt sentence, but the rebuild drops small words and
    /// possessives ("has the spreadsheet" → "the spreadsheet"). Its suggestions also replace
    /// ordinary words with names that sound alike ("already" → "Bastien", "Friday" → "Freida").
    /// So only swaps that replace a non-word or unusual name are kept ("Tyge" → "Tighe",
    /// "Bastian" → "Bastien"), and they are applied in place.
    static func applyNameFixes(_ results: [VocabularyRescorer.RescoringResult], to text: String) -> String {
        var out = text
        for r in results where r.shouldReplace {
            guard let replacement = r.replacementWord?.trimmingCharacters(in: .whitespaces), !replacement.isEmpty else { continue }
            let original = r.originalWord.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            guard !original.isEmpty, original.lowercased() != replacement.lowercased(),
                  !WordFacts.isOrdinary(original) else { continue }
            let parts = original.split(whereSeparator: { $0 == " " }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"(?<![\p{L}\p{N}])"# + parts.joined(separator: #"[\s,]+"#) + #"(?![\p{L}\p{N}])"#
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: out, range: NSRange(location: 0, length: (out as NSString).length)) else { continue }
            let matched = (out as NSString).substring(with: m.range)
            // Keep a possessive the swap would otherwise eat ("Tyge's team" → "Tighe's team").
            let possessive = matched.hasSuffix("'s") || matched.hasSuffix("’s")
            let new = possessive && !replacement.hasSuffix("s") ? replacement + String(matched.suffix(2)) : replacement
            out = (out as NSString).replacingCharacters(in: m.range, with: new)
        }
        return out
    }

    // MARK: - Segments

    /// Splits the text at sentence ends, timing each sentence from the token timings.
    /// Falls back to one segment for the whole chunk when the two can't be lined up
    /// (for example after a vocabulary replacement changed the word count).
    static func segments(text: String, timings: [TokenTiming], duration: Double) -> [Segment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let start = timings.first?.startTime ?? 0
        let end = timings.last?.endTime ?? duration
        let whole = [Segment(text: trimmed, start: start, end: end)]

        let sentences = splitSentences(trimmed)
        guard sentences.count > 1, !timings.isEmpty else { return whole }

        // Walk the tokens, closing a sentence each time its last character has been emitted.
        var segments: [Segment] = []
        var tokenIndex = 0
        for sentence in sentences {
            let target = sentence.filter { !$0.isWhitespace }.count
            var seen = 0
            let first = tokenIndex
            while tokenIndex < timings.count, seen < target {
                seen += timings[tokenIndex].token.replacingOccurrences(of: "▁", with: "").filter { !$0.isWhitespace }.count
                tokenIndex += 1
            }
            guard seen == target, tokenIndex > first else { return whole }
            segments.append(Segment(text: sentence, start: timings[first].startTime, end: timings[tokenIndex - 1].endTime))
        }
        return tokenIndex == timings.count ? segments : whole
    }

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let atEnd = i == chars.count - 1 || chars[i + 1] == " "
            if ".?!".contains(c), atEnd {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }
}
