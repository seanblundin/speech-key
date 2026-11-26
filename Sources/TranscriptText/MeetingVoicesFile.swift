import Foundation

/// Reading and renaming the voices in a saved meeting transcript, for putting real names on
/// "Speaker 2" after the fact (Sean, 2026-11-26). Everything here works on the meeting's own
/// markdown, so a name lives in that meeting's files and nowhere else: nothing about a person's
/// voice is kept, and nothing carries over to another meeting.
public enum MeetingVoicesFile {
    /// One paragraph of a transcript: "**[12:30] Speaker 2:** We could ship Friday."
    public struct Paragraph: Equatable, Sendable {
        public let seconds: TimeInterval
        public let clock: String
        public let voice: String
        public let text: String
    }

    /// Something a voice said, to recognize them by.
    public struct Quote: Equatable, Sendable {
        public let clock: String
        public let text: String
    }

    static let paragraph = try! NSRegularExpression(pattern: #"^\*\*\[([0-9:]+)\] ([^:*\n]{1,60}):\*\* (.*)$"#, options: [.anchorsMatchLines])
    /// Labels that aren't one person, so there is nobody to name.
    public static let notAPerson: Set<String> = [MeetingTranscript.me, MeetingTranscript.room]

    public static func paragraphs(_ markdown: String) -> [Paragraph] {
        let ns = markdown as NSString
        return paragraph.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).map { m in
            let clock = ns.substring(with: m.range(at: 1))
            return Paragraph(seconds: seconds(clock), clock: clock, voice: ns.substring(with: m.range(at: 2)), text: ns.substring(with: m.range(at: 3)))
        }
    }

    /// The voices that can be named, in the order they first spoke.
    public static func voices(_ markdown: String) -> [String] {
        var out: [String] = []
        for p in paragraphs(markdown) where !notAPerson.contains(p.voice) && !out.contains(p.voice) { out.append(p.voice) }
        return out
    }

    /// The same transcript with one voice's label changed, in every paragraph and in the note
    /// under the heading. Nothing inside what people said is touched.
    public static func renaming(_ markdown: String, from old: String, to new: String) -> String {
        guard old != new, !old.isEmpty, !new.isEmpty else { return markdown }
        let o = NSRegularExpression.escapedPattern(for: old), n = NSRegularExpression.escapedTemplate(for: new)
        var out = markdown.replacingOccurrences(of: #"(?m)^(\*\*\[[0-9:]+\] )"# + o + #"(:\*\* )"#, with: "$1" + n + "$2", options: .regularExpression)
        // The note is the one line in italics that starts "_Voices are told apart".
        out = out.components(separatedBy: "\n").map { line in
            guard line.hasPrefix("_Voices are told apart") else { return line }
            return line.replacingOccurrences(of: #"(?<![\p{L}\p{N}])"# + o + #"(?![\p{L}\p{N}])"#, with: n, options: .regularExpression)
        }.joined(separator: "\n")
        return out
    }

    /// A name fit to be a label, or nil: one line, no markdown, not a label that means something else.
    public static func usableName(_ raw: String) -> String? {
        let name = raw.replacingOccurrences(of: #"[\n\r*:_\[\]]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 40, !notAPerson.contains(name) else { return nil }
        return name
    }

    /// How many words a voice said.
    public static func words(of voice: String, in paragraphs: [Paragraph]) -> Int {
        paragraphs.filter { $0.voice == voice }.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    /// Up to `count` things a voice said, to jog the memory of someone who was there: full
    /// sentences of a decent length, one from each stretch of the meeting they spoke in, longest first.
    public static func quotes(of voice: String, in paragraphs: [Paragraph], count: Int = 3) -> [Quote] {
        var sentences: [(clock: String, seconds: TimeInterval, text: String, words: Int)] = []
        for p in paragraphs where p.voice == voice {
            for s in split(p.text) {
                let n = s.split(separator: " ").count
                if n >= 6 { sentences.append((p.clock, p.seconds, n > 34 ? s.split(separator: " ").prefix(34).joined(separator: " ") + "…" : s, n)) }
            }
        }
        guard !sentences.isEmpty else {
            // Someone who only ever said a few words: show those.
            return paragraphs.filter { $0.voice == voice }.prefix(count).map { Quote(clock: $0.clock, text: String($0.text.prefix(160))) }
        }
        let first = sentences.first!.seconds, span = max(1, sentences.last!.seconds - first)
        var picked: [Quote] = []
        for part in 0..<count {
            let lo = first + span * Double(part) / Double(count), hi = first + span * Double(part + 1) / Double(count)
            let inPart = sentences.filter { $0.seconds >= lo && (part == count - 1 ? $0.seconds <= hi : $0.seconds < hi) }
            if let best = inPart.max(by: { $0.words < $1.words }), !picked.contains(where: { $0.text == best.text }) {
                picked.append(Quote(clock: best.clock, text: best.text))
            }
        }
        // A voice heard in one stretch only: fill up with its next-longest sentences.
        for s in sentences.sorted(by: { $0.words > $1.words }) where picked.count < min(count, sentences.count) {
            if !picked.contains(where: { $0.text == s.text }) { picked.append(Quote(clock: s.clock, text: s.text)) }
        }
        return picked.sorted { seconds($0.clock) < seconds($1.clock) }
    }

    /// Everything a voice said as plain text, cut evenly to `limit` characters, for a summary.
    public static func said(by voice: String, in paragraphs: [Paragraph], limit: Int = 5_000) -> String {
        let texts = paragraphs.filter { $0.voice == voice }.map(\.text)
        let all = texts.joined(separator: "\n")
        guard all.count > limit, texts.count > 1 else { return String(all.prefix(limit)) }
        let each = max(120, limit / texts.count)
        return texts.map { String($0.prefix(each)) }.joined(separator: "\n").prefix(limit).description
    }

    /// The model's line about a voice, made to read the same way every time: no "The person…" or
    /// "They…" in front (it adds them whatever it is told), one sentence, and not much over 20 words.
    public static func tidyNote(_ raw: String) -> String? {
        var line = (raw.split(separator: "\n").first.map(String.init) ?? "").replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"“”"))
        line = line.replacingOccurrences(of: #"^(?i)((the|this) (person|speaker|individual|participant)|they|he|she)\s+"#, with: "", options: .regularExpression)
        if let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { line = String(line[..<end.lowerBound]) }
        var words = line.split(separator: " ").map(String.init)
        guard words.count >= 3 else { return nil }
        if words.count > 24 {
            // Cut at the last comma that leaves a full thought, else at 24 words.
            let head = words.prefix(24)
            if let comma = head.lastIndex(where: { $0.hasSuffix(",") }), comma >= 7 { words = Array(head.prefix(comma + 1)) } else { words = Array(head) }
        }
        line = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
        return line.prefix(1).uppercased() + line.dropFirst() + "."
    }

    static func split(_ text: String) -> [String] {
        var out: [String] = [], current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            if ".?!".contains(c), i == chars.count - 1 || chars[i + 1] == " " {
                out.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// "12:30" → 750, "1:02:05" → 3725.
    static func seconds(_ clock: String) -> TimeInterval {
        clock.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
}
