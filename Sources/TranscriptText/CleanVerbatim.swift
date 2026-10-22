import Foundation

/// Minimal cleanup that keeps Sean's words, order and tone.
///
/// It removes only:
/// - um, uh and similar sounds,
/// - immediate stutters of small words ("the the", "I, I think"),
/// - immediate restarts of a phrase ("the demo, the demo is" → "the demo is"),
/// - "like" when it is set off by commas as a filler.
///
/// It never removes anything across a sentence end, so a repeated sentence
/// ("I think it's good. I think it's good.") stays, and "you know" or "I mean" stay too.
public enum CleanVerbatim {
    static let fillers: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "erm", "er", "hmm", "hmmm", "mm", "mmm"]

    /// Small words that are never doubled on purpose. Words like "that", "had", "very" and "no"
    /// can be (“that that”, “very, very”), so they are left alone.
    static let stutterWords: Set<String> = [
        "the", "a", "an", "and", "i", "to", "of", "in", "it", "it's", "i'm", "we", "you", "but", "or",
        "for", "with", "on", "at", "my", "our", "this", "they", "he", "she", "if", "when", "so", "is", "are",
        "was", "be", "can", "just", "like", "what", "how", "why", "we're", "they're", "you're", "there",
    ]

    struct Token {
        var lead: String     // punctuation before the word, e.g. an opening quote
        var core: String     // the word itself
        var trail: String    // punctuation after it
        var key: String { core.lowercased().replacingOccurrences(of: "’", with: "'") }
        var endsSentence: Bool { trail.contains(where: { ".!?".contains($0) }) }
        var hasComma: Bool { trail.contains(",") }
        var text: String { lead + core + trail }
    }

    public static func apply(_ text: String) -> String {
        var tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }
        tokens = removeFillers(tokens)
        tokens = removeLikeFiller(tokens)
        tokens = collapseRepeats(tokens)
        return tidy(tokens.map(\.text).joined(separator: " "))
    }

    // MARK: - Steps

    static func tokenize(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace }).map { raw in
            let s = String(raw)
            let isWordChar: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "-" }
            guard let first = s.firstIndex(where: isWordChar), let last = s.lastIndex(where: isWordChar) else {
                return Token(lead: s, core: "", trail: "")
            }
            return Token(lead: String(s[..<first]), core: String(s[first...last]), trail: String(s[s.index(after: last)...]))
        }
    }

    static func removeFillers(_ input: [Token]) -> [Token] {
        var out: [Token] = []
        for t in input {
            guard fillers.contains(t.key) else { out.append(t); continue }
            guard !out.isEmpty else { continue }
            if t.endsSentence {
                // "and then, um." → "and then."
                let end = t.trail.filter { ".!?".contains($0) }
                out[out.count - 1].trail = out[out.count - 1].trail.replacingOccurrences(of: ",", with: "") + end
            } else if t.hasComma, out[out.count - 1].hasComma {
                // "and, uh, the" → "and the"
                out[out.count - 1].trail = out[out.count - 1].trail.replacingOccurrences(of: ",", with: "")
            }
        }
        return out
    }

    static func removeLikeFiller(_ input: [Token]) -> [Token] {
        var out: [Token] = []
        for t in input {
            if t.key == "like", t.hasComma, !t.endsSentence {
                let sentenceInitial = out.isEmpty || out[out.count - 1].endsSentence
                let afterComma = !out.isEmpty && out[out.count - 1].hasComma
                if sentenceInitial { continue }                 // "Like, I think" → "I think"
                if afterComma {                                 // "and, like, Elijah" → "and Elijah"
                    out[out.count - 1].trail = out[out.count - 1].trail.replacingOccurrences(of: ",", with: "")
                    continue
                }
            }
            out.append(t)
        }
        return out
    }

    static func collapseRepeats(_ input: [Token]) -> [Token] {
        var tokens = input
        var changed = true
        while changed {
            changed = false
            // Longer phrases first, so "the Zentro demo, the Zentro demo" collapses as one unit.
            outer: for n in stride(from: 6, through: 1, by: -1) {
                guard tokens.count >= 2 * n else { continue }
                for i in n...(tokens.count - n) {
                    let first = tokens[(i - n)..<i], second = tokens[i..<(i + n)]
                    guard first.map(\.key) == second.map(\.key), !first.contains(where: { $0.core.isEmpty }) else { continue }
                    // Never across a sentence end, and nothing inside the first copy may end a sentence.
                    guard !first.contains(where: \.endsSentence) else { continue }
                    if n == 1 && !stutterWords.contains(first.first!.key) { continue }
                    // Keep the second copy (it carries the sentence on) and drop the first.
                    let keepCapital = first.first!.core.first?.isUppercase == true
                    tokens.removeSubrange((i - n)..<i)
                    if keepCapital, let c = tokens[i - n].core.first, c.isLowercase {
                        tokens[i - n].core = c.uppercased() + tokens[i - n].core.dropFirst()
                    }
                    changed = true
                    break outer
                }
            }
        }
        return tokens
    }

    /// Fix spacing and capitals left behind by removals.
    static func tidy(_ s: String) -> String {
        var t = s
        let fixes: [(String, String)] = [
            // A period right before a letter is a file extension ("a .md file"), not the end of a sentence.
            (#"\s+([,;:!?]|\.(?![\p{L}\p{N}]))"#, "$1"),
            (#",{2,}"#, ","),
            (#",([.!?])"#, "$1"),
            (#"^[\s,;:]+"#, ""),
            (#"([.!?])\s*,+"#, "$1"),
            (#"\s{2,}"#, " "),
        ]
        for (pattern, template) in fixes {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        t = capitalizeSentenceStarts(t)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func capitalizeSentenceStarts(_ s: String) -> String {
        var chars = Array(s)
        var capitalizeNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                if c.isLowercase { chars[i] = Character(c.uppercased()) }
                capitalizeNext = false
            } else if ".!?".contains(c) {
                // Only a sentence end when what follows is a space, a closing quote, or nothing: "readme.md" stays lowercase.
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                capitalizeNext = next.isWhitespace || "\"”)".contains(next)
            } else if !c.isWhitespace && !"\"“(".contains(c) {
                capitalizeNext = false
            }
        }
        return String(chars)
    }
}

/// Joins the text of consecutive audio chunks, repairing what the cut did to the seam.
public enum ChunkJoiner {
    public static func join(_ parts: [String]) -> String {
        var out = ""
        for raw in parts {
            var next = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !next.isEmpty else { continue }
            guard !out.isEmpty else { out = next; continue }
            // A word cut in half shows up at the end of one chunk and the start of the next.
            if let last = lastWord(out), let first = firstWord(next), last == first {
                next = String(next.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces)
                if next.isEmpty { continue }
            }
            // The model ends every chunk with a period; drop it when the sentence clearly goes on.
            if out.hasSuffix("."), let c = next.first, c.isLowercase { out.removeLast() }
            // Chunks are cut at pauses, usually sentence ends. If the model left the period off but
            // the next chunk opens a new sentence with an ordinary word ("Then", "Does"), add it.
            if let lastChar = out.last, !".?!,;:".contains(lastChar),
               let first = next.split(separator: " ").first, let c = first.first, c.isUppercase,
               first != "I", Glossary.CommonWords.contains(String(first).trimmingCharacters(in: .punctuationCharacters)) {
                out += "."
            }
            out += " " + next
        }
        return out
    }

    static func lastWord(_ s: String) -> String? {
        s.split(separator: " ").last.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
    }

    static func firstWord(_ s: String) -> String? {
        s.split(separator: " ").first.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
    }
}
