import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What Sean asked Utter to do, read from his words.
struct ParsedCommand: Equatable {
    enum Action: String { case addToGlossary, removeFromGlossary, startMeeting, endMeeting, snapshot, undo, reply, unclear }
    var action: Action
    var correct = ""
    var wrong: [String] = []
    /// For `.reply`: a short answer to show in the pill. Nothing is changed.
    var reply = ""
}

/// Turns a spoken command into a `ParsedCommand`. Today that's Apple's on-device model, so
/// nothing leaves the Mac. A smarter brain (Claude) would be another conformer.
@MainActor
protocol CommandBrain {
    /// nil when ready; otherwise why it can't run, in words Sean can act on.
    var unavailableReason: String? { get }
    var name: String { get }
    func prewarm()
    func interpret(_ text: String) async throws -> ParsedCommand
}

@MainActor
func makeCommandBrain() -> CommandBrain {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) { return OnDeviceBrain() }
    #endif
    return NoBrain()
}

private struct NoBrain: CommandBrain {
    var unavailableReason: String? { "Talking to the agent needs macOS 26 (Tahoe) with Apple Intelligence" }
    var name: String { "None" }
    func prewarm() {}
    func interpret(_ text: String) async throws -> ParsedCommand { ParsedCommand(action: .unclear) }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable enum GeneratedAction {
    case fixWord, removeFix, startMeeting, endMeeting, snapshot, undo, reply
}

@available(macOS 26.0, *)
@Generable struct GeneratedCommand {
    var action: GeneratedAction
    @Guide(description: "fixWord/removeFix only: the correct spelling. Otherwise empty.")
    var correct: String
    @Guide(description: "fixWord/removeFix only: the wrong spellings you wrote. Never the correct one. Otherwise empty.", .maximumCount(3))
    var wrong: [String]
    @Guide(description: "reply only: a short, friendly answer of at most 12 words. Otherwise empty.")
    var reply: String
}

/// Apple's on-device language model (Apple Intelligence). About 1.2 s per command on an M2.
@available(macOS 26.0, *)
@MainActor
final class OnDeviceBrain: CommandBrain {
    var name: String { "Apple Intelligence, on this Mac" }

    /// Tested 2026-10-20 on 12 phrasings, including "Are you self-aware? … respond with a yes in
    /// the pill", which the first prompt turned into a glossary row. Every action came out right.
    /// The model fills fields it shouldn't (a "correct" on a reply, extra wrong spellings), so
    /// CommandRunner only reads the fields that belong to the action, and checks the wrong words
    /// against what Utter actually wrote.
    static let instructions = """
    You are the agent inside Speech Key, a dictation app on the user's Mac. The user holds a key and speaks to you; you get the transcript.

    Most of the time the user is telling you that you wrote a word wrong. That is fixWord. Choose fixWord only when the user names a word you wrote wrong and what it should be.
    removeFix: the user wants you to stop making a fix.
    startMeeting, endMeeting, snapshot: meeting transcription. A snapshot saves the transcript so far.
    undo: take back your last change.
    reply: anything else, such as a question, small talk, or a request you can't do. Answer it briefly and honestly. Never change anything for a reply. You can't see the time, the screen, the web, or what was said in meetings, so don't pretend to.

    A word written like JIMMY [spelled] was spelled out letter by letter: it is the exact spelling.

    Examples:
    "Jammy should be Jimmy, he's my friend" → fixWord, correct Jimmy, wrong [Jammy]
    "When you hear Teegh, write Tighe" → fixWord, correct Tighe, wrong [Teegh]
    "Your last one said Kelsey instead of Kalshi" → fixWord, correct Kalshi, wrong [Kelsey]
    "Stop changing Jammy to Jimmy" → removeFix, correct Jimmy, wrong [Jammy]
    "Take a snapshot" → snapshot
    "Never mind, take that back" → undo
    "Are you there?" → reply "Yes, I'm here."
    "Can you write my email for me?" → reply "Not yet. I fix words and run meetings."
    "Summarize my last meeting" → reply "I can't read meetings yet. Ask Claude."
    """

    private var warm: LanguageModelSession?

    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to talk to the agent"
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading its model"
        case .unavailable(.deviceNotEligible): return "This Mac can’t run Apple Intelligence"
        case .unavailable: return "Apple Intelligence isn’t available"
        }
    }

    func prewarm() {
        guard unavailableReason == nil, warm == nil else { return }
        let s = LanguageModelSession(instructions: Self.instructions)
        s.prewarm()
        warm = s
    }

    func interpret(_ text: String) async throws -> ParsedCommand {
        // A fresh session each time, so one command never colours the next.
        let session = warm ?? LanguageModelSession(instructions: Self.instructions)
        warm = nil
        defer { prewarm() }
        let response = try await session.respond(to: text, generating: GeneratedCommand.self,
                                                 options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 120))
        let c = response.content
        let action: ParsedCommand.Action
        switch c.action {
        case .fixWord: action = .addToGlossary
        case .removeFix: action = .removeFromGlossary
        case .startMeeting: action = .startMeeting
        case .endMeeting: action = .endMeeting
        case .snapshot: action = .snapshot
        case .undo: action = .undo
        case .reply: action = .reply
        }
        return ParsedCommand(action: action, correct: c.correct, wrong: c.wrong, reply: c.reply)
    }
}
#endif
