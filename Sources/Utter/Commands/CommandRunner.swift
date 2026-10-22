import AppKit
import SpeechEngine

/// Carries out what Sean says to Utter (⇧ fn): glossary fixes, meeting controls, undo.
@MainActor
final class CommandRunner {
    let brain: CommandBrain
    private let glossary: GlossaryStore
    private let meeting: MeetingController
    private let pill: PillController
    private let history: History
    private let log: DictationLog

    init(brain: CommandBrain, glossary: GlossaryStore, meeting: MeetingController, pill: PillController,
         history: History, log: DictationLog) {
        self.brain = brain
        self.glossary = glossary
        self.meeting = meeting
        self.pill = pill
        self.history = history
        self.log = log
    }

    /// Test modes quit when a command is done.
    var onFinished: (() -> Void)?

    func run(_ text: String, raw: String) {
        if let why = brain.unavailableReason {
            finish(text: text, raw: raw, reply: why, ok: false)
            return
        }
        pill.model.talkingToUtter = true
        pill.show(.working)
        Task {
            let started = Date()
            let (input, spelled) = SpelledLetters.join(text)
            let parsed: ParsedCommand
            do { parsed = try await brain.interpret(input) } catch {
                UtterLog.write("command failed: \(error)")
                finish(text: text, raw: raw, reply: "Couldn’t work that out. Try again?", ok: false)
                return
            }
            UtterLog.write(String(format: "command %.1fs: \"%@\" → %@ %@ %@", Date().timeIntervalSince(started), input,
                                  parsed.action.rawValue, parsed.correct, parsed.wrong.joined(separator: ",")))
            let (reply, ok, showsOwnPill) = execute(parsed, said: text, spelled: spelled)
            finish(text: text, raw: raw, reply: reply, ok: ok, showPill: !showsOwnPill, isReply: parsed.action == .reply)
        }
    }

    private func execute(_ c: ParsedCommand, said text: String, spelled: [String]) -> (String, ok: Bool, showsOwnPill: Bool) {
        switch c.action {
        case .addToGlossary:
            switch CommandWords.tidy(correct: c.correct, wrong: c.wrong, spelled: spelled, said: text) {
            case .missing:
                return ("Say what Speech Key writes instead, like “Jammy should be Jimmy”", false, false)
            case .sameWord(let w):
                return ("Both words came out as “\(w)”. Try again and spell the right one letter by letter", false, false)
            case .ok(let correct, let wrong):
                // Only fix words Utter really wrote. The model sometimes turns a question into a
                // "fix" (2026-10-20: "yes, pill, UI → self-aware"), and adds made-up variants.
                let seen = wrong.filter(RecentText.contains)
                guard !seen.isEmpty else {
                    let w = wrong.first ?? ""
                    return ("I haven't written “\(w)” lately, so I left your glossary alone", false, false)
                }
                do { return (try glossary.add(heard: seen, correct: correct, source: .voice), true, false) }
                catch { return (error.localizedDescription, false, false) }
            }
        case .removeFromGlossary:
            let words = ([c.correct] + c.wrong).map { $0.replacingOccurrences(of: " [spelled]", with: "") }
            do {
                if let label = try glossary.remove(words) { return (label, true, false) }
                return ("No glossary fix matches “\(words.filter { !$0.isEmpty }.joined(separator: ", "))”", false, false)
            } catch { return (error.localizedDescription, false, false) }
        case .undo:
            do {
                if let label = try glossary.undo() { return (label, true, false) }
                return ("Nothing to undo", false, false)
            } catch { return (error.localizedDescription, false, false) }
        case .startMeeting:
            if meeting.isRunning { return ("A meeting is already running", false, false) }
            meeting.start()
            return ("Started a meeting", true, true)
        case .endMeeting:
            if !meeting.isRunning { return ("No meeting is running", false, false) }
            meeting.end()
            return ("Ended the meeting", true, true)
        case .snapshot:
            if !meeting.isRunning { return ("No meeting is running", false, false) }
            meeting.snapshot()
            return ("Saved a snapshot", true, true)
        case .reply:
            let text = Self.short(c.reply)
            return (text.isEmpty ? "I can fix words, run meetings, and undo" : text, true, false)
        case .unclear:
            return ("I can fix words, run meetings, and undo", false, false)
        }
    }

    /// First sentence, cut to fit the pill.
    static func short(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = t.firstIndex(where: { ".!?".contains($0) }), t.distance(from: t.startIndex, to: end) > 8 {
            t = String(t[...end])
        }
        return t.count > 70 ? String(t.prefix(68)).trimmingCharacters(in: .whitespaces) + "…" : t
    }

    private func finish(text: String, raw: String, reply: String, ok: Bool, showPill: Bool = true, isReply: Bool = false) {
        if showPill {
            if isReply { pill.show(.reply(reply), autoHideAfter: 4) }
            else { pill.show(ok ? .done(reply) : .message(reply), autoHideAfter: ok ? 2.4 : 3.5) }
        }
        pill.model.talkingToUtter = false
        print("[utter] command: \(text) → \(reply)")
        fflush(stdout)
        var entry = DictationLog.Entry(time: Date(), app: NSWorkspace.shared.frontmostApplication?.localizedName, raw: raw,
                                       final: text, changes: [], audioSeconds: 0, waitSeconds: 0)
        entry.kind = "command"
        entry.reply = reply
        log.append(entry)
        history.add(entry)
        onFinished?()
    }
}

/// What Utter wrote recently: the last 200 dictations (as heard and as pasted) and the newest
/// meeting transcript. A word Sean calls wrong has to be in here.
@MainActor
enum RecentText {
    static func contains(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return false }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: w).replacingOccurrences(of: " ", with: "\\s+") + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return corpus().contains { re.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
    }

    private static func corpus() -> [String] {
        var texts = DictationLog.recent(limit: 200).flatMap { [$0.raw, $0.final] }
        let fm = FileManager.default
        if let folders = try? fm.contentsOfDirectory(at: MeetingController.root, includingPropertiesForKeys: nil),
           let newest = folders.filter({ !$0.lastPathComponent.hasPrefix(".") }).map(\.lastPathComponent).sorted().last {
            let dir = MeetingController.root.appendingPathComponent(newest)
            for name in ["full.md", MeetingRecovery.liveName] {
                if let t = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) { texts.append(t) }
            }
        }
        return texts
    }
}
