import Foundation
import TranscriptText

/// A plain-text pulse on the cleanup, read from the logs. For questions like "look at my recent
/// cleanup history, is it working well?": run `SpeechKey --cleanup-report 7` and read the output.
///
/// `--cleanup-replay [kinds]` instead reruns today's rules over every logged dictation's raw
/// words, to check a rule change against real speech before it ships.
enum CleanupReport {
    static func runIfAsked(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--cleanup-report") {
            let days = i + 1 < args.count ? Double(args[i + 1]) ?? 7 : 7
            print(report(days: days))
            return true
        }
        if let i = args.firstIndex(of: "--cleanup-replay") {
            let kinds = i + 1 < args.count ? Set(args[i + 1].split(separator: ",").map(String.init)) : []
            print(replay(kinds: kinds))
            return true
        }
        return false
    }

    static func report(days: Double) -> String {
        let since = Date().addingTimeInterval(-days * 86_400)
        let all: [DictationLog.Entry] = DictationLog.read(DictationLog.file)
        let entries = all.filter { $0.time >= since && $0.kind == nil && $0.app != "simulation" }
        let logged = entries.filter { $0.cleanup != nil }
        var out: [String] = []
        out.append("# Speech Key cleanup, last \(Int(days)) days")
        out.append("")
        guard !logged.isEmpty else {
            out.append("\(entries.count) dictations, none with cleanup records yet (they start with version 0.2.3).")
            return out.joined(separator: "\n")
        }
        let words = logged.reduce(0) { $0 + $1.raw.split(separator: " ").count }
        let touched = logged.filter { !($0.cleanup ?? []).isEmpty }
        let waits = logged.map(\.waitSeconds).sorted()
        out.append("\(logged.count) dictations, \(words) words. Cleanup changed \(touched.count) of them (\(percent(touched.count, logged.count))).")
        out.append(String(format: "Wait after releasing the key: median %.2f s, slowest tenth from %.2f s.", waits[waits.count / 2], waits[min(waits.count - 1, waits.count * 9 / 10)]))
        out.append("")

        // What the cleanup did, by kind.
        var byKind: [CleanVerbatim.Edit.Kind: [(DictationLog.Entry, CleanVerbatim.Edit)]] = [:]
        for e in logged { for edit in e.cleanup ?? [] { byKind[edit.kind, default: []].append((e, edit)) } }
        out.append("## What it took out")
        for kind in [CleanVerbatim.Edit.Kind.filler, .repeat, .fragment, .glitch] {
            let list = byKind[kind] ?? []
            out.append("")
            out.append("**\(kind.rawValue)** (\(explain(kind))): \(list.count)")
            for (_, edit) in list.suffix(10).reversed() {
                out.append("- cut “\(edit.cut)” in: \(edit.near)")
            }
        }
        let names = logged.flatMap(\.changes)
        out.append("")
        out.append("**names fixed from the glossary**: \(names.count)")
        for (fix, n) in Dictionary(grouping: names, by: { $0 }).mapValues(\.count).sorted(by: { $0.value > $1.value }).prefix(12) {
            out.append("- \(fix) ×\(n)")
        }

        // Signs it got something wrong.
        let events = EventLog.all().filter { $0.time >= since }
        let rawCopies = events.filter { $0.kind == .rawCopied }
        let corrections: [DictationLog.Correction] = (DictationLog.read(DictationLog.correctionsFile) as [DictationLog.Correction]).filter { $0.time >= since }
        let learned = events.filter { $0.kind == .glossaryAdded && $0.source == "learned" }
        let undone = events.filter { $0.source == "undo" }
        out.append("")
        out.append("## Signs it got something wrong")
        out.append("")
        out.append("**Raw copied instead of the cleaned text** (the cleanup was in the way): \(rawCopies.count)")
        for e in rawCopies.suffix(8) {
            guard let t = e.dictation, let d = logged.first(where: { abs($0.time.timeIntervalSince(t)) < 0.002 }) else { continue }
            out.append("- raw:     \(clip(d.raw))")
            out.append("  cleaned: \(clip(d.final))")
        }
        out.append("")
        out.append("**Fixed by hand in History**: \(corrections.count)")
        for c in corrections.suffix(8) {
            out.append("- before: \(clip(c.before))")
            out.append("  after:  \(clip(c.after))")
        }
        out.append("")
        out.append("**Names learned from spelling out loud**: \(learned.count)" + (learned.isEmpty ? "" : " (" + learned.map { "\($0.heard ?? "") → \($0.write ?? "")" }.joined(separator: "; ") + ")"))
        out.append("**Glossary changes undone**: \(undone.count)")
        out.append("")
        out.append("How to judge: read the cuts above. A cut is wrong if the words carried meaning. Raw copies and hand fixes are the strongest signs of trouble; a healthy week has almost none.")
        return out.joined(separator: "\n")
    }

    static func replay(kinds: Set<String>) -> String {
        let all: [DictationLog.Entry] = DictationLog.read(DictationLog.file)
        var out: [String] = []
        var counts: [String: Int] = [:]
        for (i, e) in all.enumerated() where e.kind == nil {
            for edit in CleanVerbatim.applyNoting(e.raw).edits where kinds.isEmpty || kinds.contains(edit.kind.rawValue) {
                counts[edit.kind.rawValue, default: 0] += 1
                out.append("[\(i)] \(edit.kind.rawValue): cut “\(edit.cut)” in: \(edit.near)")
            }
        }
        if kinds.isEmpty || kinds.contains("lesson") {
            for (i, e) in all.enumerated() where e.kind == nil {
                for lesson in SpelledNames.lessons(in: e.raw) {
                    counts["lesson", default: 0] += 1
                    out.append("[\(i)] lesson: \(lesson.heard) → \(lesson.write)")
                }
            }
        }
        out.append("\(all.count) entries. " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        return out.joined(separator: "\n")
    }

    private static func explain(_ kind: CleanVerbatim.Edit.Kind) -> String {
        switch kind {
        case .filler: return "um, uh, a comma-wrapped “like”"
        case .repeat: return "a word or phrase said twice in a row"
        case .fragment: return "the cut-off start of a word"
        case .glitch: return "a mark the recognizer left behind"
        }
    }

    private static func percent(_ a: Int, _ b: Int) -> String { b == 0 ? "0%" : "\(Int((Double(a) / Double(b) * 100).rounded()))%" }
    private static func clip(_ s: String) -> String { s.count > 220 ? String(s.prefix(220)) + "…" : s }
}
