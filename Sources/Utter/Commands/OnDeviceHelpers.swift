import Foundation
import TranscriptText
#if canImport(FoundationModels)
import FoundationModels
#endif

// Two more jobs for Apple's on-device model (Apple Intelligence), so they stay on the Mac:
// titling meetings, and deciding glossary fixes whose notes set a condition.

// MARK: - Meeting titles

/// Writes a short title and a one-line summary for each meeting, in the background, one meeting at
/// a time. Runs at a meeting's first snapshot and at its end, and once for older meetings that have
/// none. A title Sean wrote himself is never replaced.
@MainActor
final class MeetingTitler {
    /// Called when a meeting gets its title, so the Meetings tab can refresh.
    var onUpdate: (() -> Void)?
    /// Meetings being titled right now, for "Writing a title…".
    private(set) var working: Set<URL> = []
    private var queue: [URL] = []
    private var running = false

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    /// Queues a meeting. `force`: title it again even if it has an agent-written title (at the end).
    func title(_ folder: URL, force: Bool = false) {
        guard isAvailable else { return }
        let meta = MeetingMeta.load(folder)
        if meta?.titleBy == "you" { return }
        if !force, meta?.title != nil { return }
        if !queue.contains(folder) { queue.append(folder) }
        working.insert(folder)
        onUpdate?()
        pump()
    }

    /// Titles every meeting that has none, newest first.
    func backfill(root: URL) {
        for m in MeetingLibrary.list(in: root) where m.title == nil && m.titleBy != "you"
            && MeetingMeta.load(m.folder)?.titleFailed != true { title(m.folder) }
    }

    private func pump() {
        guard !running, let folder = queue.first else { return }
        running = true
        Task { @MainActor in
            defer {
                queue.removeAll { $0 == folder }
                working.remove(folder)
                running = false
                onUpdate?()
                pump()
            }
            guard let text = MeetingLibrary.transcriptText(folder) else { return }
            let started = Date()
            guard let result = await Self.generate(text) else {
                // Don't retry this one on every launch; the meeting's end still tries again.
                MeetingMeta.update(folder) { $0.titleFailed = true }
                return
            }
            // Sean may have typed a title meanwhile.
            if MeetingMeta.load(folder)?.titleBy == "you" { return }
            MeetingMeta.update(folder) { m in
                m.title = result.title
                m.summary = result.summary
                m.titleBy = "agent"
                m.titleFailed = nil
            }
            UtterLog.write(String(format: "meeting titled in %.1fs: %@", Date().timeIntervalSince(started), folder.lastPathComponent))
        }
    }

    static func generate(_ transcript: String) async -> (title: String, summary: String)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return await OnDeviceMeetingTitle.generate(transcript) }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
enum OnDeviceMeetingTitle {
    static let instructions = """
    You title meeting transcripts. "Me" is the user; "Them" is everyone else on the call. Be concrete and plain: \
    name the project, company, product or event if one is clear. Never invent facts.
    """

    /// The model's context is small (about 4,000 tokens), so long meetings are summarized in pieces first.
    static let piece = 7_000

    /// Summarizing the user's own meeting is a content transformation, so the permissive guardrails
    /// apply. With the default ones, about a third of real meetings were refused as "may contain
    /// sensitive content" (2026-10-22). They only relax plain-text answers, hence the "Title:" lines
    /// instead of a generated struct.
    static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    static func generate(_ transcript: String) async -> (title: String, summary: String)? {
        do {
            var material = transcript
            if transcript.count > piece {
                var notes: [String] = []
                var rest = Substring(transcript)
                while !rest.isEmpty, notes.count < 12 {
                    let chunk = rest.prefix(piece)
                    rest = rest.dropFirst(chunk.count)
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    let r = try await session.respond(
                        to: "In two short sentences, say what this part of a meeting covered and anything decided.\n\n\(chunk)",
                        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 90))
                    notes.append(r.content)
                }
                material = notes.joined(separator: "\n")
            }
            let session = LanguageModelSession(model: model, instructions: instructions)
            let r = try await session.respond(to: """
                Meeting \(transcript.count > piece ? "notes" : "transcript"):

                \(material.prefix(piece))

                Answer in exactly two lines:
                Title: a plain title of 3 to 6 words naming what the meeting was about, with no quotes and no date
                Summary: one plain sentence under 20 words saying what was discussed or decided
                """, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 80))
            return parse(r.content)
        } catch {
            UtterLog.write("meeting title failed: \(error)")
            return nil
        }
    }

    /// "Title: Launch page review\nSummary: …" → the two parts, without markdown or quotes.
    static func parse(_ text: String) -> (title: String, summary: String)? {
        var title = "", summary = ""
        let junk = CharacterSet(charactersIn: " *_\"“”.")
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*_"))
            if l.lowercased().hasPrefix("title:") { title = String(l.dropFirst(6)).trimmingCharacters(in: junk) }
            else if l.lowercased().hasPrefix("summary:") {
                summary = String(l.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: " *_\"“”"))
            }
        }
        return title.isEmpty ? nil : (title, summary)
    }
}
#endif

// MARK: - Glossary rows with a condition

/// Decides the glossary fixes that need judgment: rows whose notes set a condition ("only in
/// Book club talk"), or a heard form two rows claim ("Eli": Elijah or Elias Moreno). Only runs when
/// such a word is in the dictation, and gives up after 1.5 s, leaving the words as heard
/// (Sean, 2026-10-21).
@MainActor
final class GlossaryJudge {
    static let timeout: TimeInterval = 1.5

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    /// Words to change, and what to change them to. Empty when nothing applies, the model is
    /// unavailable, or it took too long.
    func decide(text: String, candidates: [Glossary.ConditionalCandidate]) async -> [(word: String, target: String)] {
        guard !candidates.isEmpty, isAvailable else { return [] }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let started = Date()
            let picks = await withTaskGroup(of: [Int]?.self) { group -> [Int]? in
                group.addTask { await OnDeviceJudge.picks(text: text, candidates: candidates) }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            UtterLog.write(String(format: "glossary judge %.2fs for %@: %@", Date().timeIntervalSince(started),
                                  candidates.map(\.word).joined(separator: ", "), picks.map { "\($0)" } ?? "timed out"))
            guard let picks else { return [] }
            var out: [(word: String, target: String)] = []
            for (c, pick) in zip(candidates, picks) where pick > 0 && pick <= c.options.count {
                out.append((c.word, c.options[pick - 1].target))
            }
            return out
        }
        #endif
        return []
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable struct GeneratedPicks {
    @Guide(description: "One number per word, in the order given: 0 to leave the word as written, otherwise the number of the option that fits.")
    var picks: [Int]
}

@available(macOS 26.0, *)
enum OnDeviceJudge {
    static let instructions = """
    You check a dictated message for words that may have been misheard. For each word you get the options from \
    the user's glossary, each with a note saying when it applies. Pick an option only when the message clearly \
    fits its note. When unsure, answer 0 and leave the word as written.
    """

    static func picks(text: String, candidates: [Glossary.ConditionalCandidate]) async -> [Int]? {
        var prompt = "Message: \(text)\n"
        for (i, c) in candidates.enumerated() {
            prompt += "\nWord \(i + 1): \"\(c.word)\"\n  0. leave it as written\n"
            for (j, o) in c.options.enumerated() {
                prompt += "  \(j + 1). \(o.target)\(o.note.isEmpty ? "" : " (\(o.note))")\n"
            }
        }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: prompt, generating: GeneratedPicks.self,
                                              options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 30))
            return r.content.picks
        } catch {
            return nil
        }
    }
}
#endif
