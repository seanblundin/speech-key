import Foundation

/// Minimal cleanup that keeps Sean's words, order and tone.
///
/// It removes only:
/// - um, uh and similar sounds,
/// - immediate stutters of small connecting words ("the the", "I, I think", "should should"),
/// - immediate restarts of a phrase ("the demo, the demo is" → "the demo is"),
/// - "like" when it is set off by commas as a filler,
/// - the cut-off start of a word that is then said in full ("w white paper", "s within"),
/// - marks the recognizer leaves for a sound it has no letter for ("Q<unk>A" → "Q&A").
///
/// It never removes anything across a sentence end, so a repeated sentence
/// ("I think it's good. I think it's good.") stays, and "you know" or "I mean" stay too.
/// It never rewrites: every word left is a word Sean said, in the order he said it.
public enum CleanVerbatim {
    /// One thing the cleanup took out, for the log: what kind, the words, and where.
    public struct Edit: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// um, uh, and "like" set off by commas.
            case filler
            /// A word or phrase said twice in a row.
            case `repeat`
            /// The cut-off start of a word.
            case fragment
            /// A mark the recognizer left behind.
            case glitch
        }
        public let kind: Kind
        /// The words taken out.
        public let cut: String
        /// A few words around them, as they read before the cut.
        public let near: String
    }

    static let fillers: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "erm", "er", "hmm", "hmmm", "mm", "mmm"]

    /// Small connecting words that are never doubled on purpose, so two in a row is a stutter
    /// ("the the", "of of", "I, I think"). Nouns, adjectives and verbs are never on this list:
    /// people double those on purpose ("the master master folder", "final final take"), and a rule
    /// that collapsed every doubled word cut five of Sean's that way in its first week (2026-11-26).
    /// Also not here: "that" and "had" ("that that", "had had"), "no", "very", "really", "do".
    static let stutterWords: Set<String> = [
        "the", "a", "an", "and", "i", "to", "of", "in", "it", "it's", "i'm", "we", "you", "but", "or",
        "for", "with", "on", "at", "my", "our", "this", "they", "he", "she", "if", "when", "so", "is", "are",
        "was", "be", "can", "just", "like", "what", "how", "why", "we're", "they're", "you're", "there",
        "as", "your", "their", "its", "his", "her", "them", "me", "us", "him", "these", "those", "by", "from",
        "into", "about", "than", "then", "which", "who", "where", "while", "because", "after", "before", "via", "per",
        "should", "would", "could", "will", "have", "has", "does", "did", "were", "been", "am",
        "let's", "that's", "there's", "here's", "he's", "she's", "i've", "we've", "you've", "i'd", "we'd", "i'll", "we'll",
        "it'll", "don't", "doesn't", "didn't", "isn't", "aren't", "wasn't", "can't", "won't",
        "each", "every", "some", "any", "also", "maybe", "once",
    ]

    /// Lone letters that are only ever the cut-off start of a word. Not c, k, n, q, x, y, z, and no
    /// vowels: those show up as real words or labels ("plan c", "x axis", "rock n roll").
    static let fragmentLetters: Set<String> = ["b", "d", "f", "g", "h", "j", "l", "m", "p", "r", "s", "t", "v", "w"]
    /// Word starts that aren't words themselves.
    static let fragmentStarts: Set<String> = [
        "th", "sh", "wh", "fr", "tr", "gr", "br", "pl", "sl", "sm", "sn", "sw", "tw", "dr", "cr", "fl", "bl",
        "kn", "wr", "qu", "st", "str", "thr", "shr", "spr", "scr",
    ]
    /// A lone letter after one of these is a label ("plan b", "press s", "column d"), not a fragment.
    static let labelWords: Set<String> = [
        "plan", "option", "part", "type", "vitamin", "grade", "series", "class", "section", "appendix", "exhibit",
        "version", "phase", "team", "group", "level", "tier", "letter", "letters", "column", "row", "key", "press",
        "hit", "hold", "step", "item", "point", "variable", "command", "cmd", "control", "ctrl", "shift", "alt",
        "fn", "globe", "drive", "model", "figure", "table", "room", "gate", "terminal", "line", "track", "round",
        "big", "capital", "lowercase", "uppercase", "small", "and", "or",
    ]
    /// A lone letter before one of these is half a compound ("t shirt", "b roll", "p value").
    static let compoundSeconds: Set<String> = [
        "shirt", "shirts", "mail", "ray", "roll", "test", "tests", "axis", "value", "values", "dash", "drive",
        "sharp", "minor", "major", "flat", "mobile", "day", "plus", "minus", "equals", "school", "team", "side",
        "list", "key", "word", "bomb", "shape", "shaped", "bone", "rex", "pain", "curve", "neck", "pad", "train",
        "trap", "stop", "class", "force", "forces", "plot", "junction", "string", "line", "block", "wing", "cup",
        "type", "tier", "plan", "squad", "level", "grade", "movie", "rated", "spot", "zone", "ring", "frame",
        "series", "band", "cell", "wave", "score", "turn", "bar", "corp", "student", "students", "player", "players",
    ]

    struct Token {
        var lead: String     // punctuation before the word, e.g. an opening quote
        var core: String     // the word itself
        var trail: String    // punctuation after it
        var key: String { core.lowercased().replacingOccurrences(of: "’", with: "'") }
        var endsSentence: Bool { trail.contains(where: { ".!?".contains($0) }) }
        var hasComma: Bool { trail.contains(",") }
        var text: String { lead + core + trail }
        var isLoneLetter: Bool { core.count == 1 && core.first!.isLetter && key != "a" && key != "i" }
        var hasDigit: Bool { core.contains(where: \.isNumber) }
    }

    public static func apply(_ text: String) -> String { applyNoting(text).text }

    /// The cleaned text, plus what was taken out and why.
    public static func applyNoting(_ text: String) -> (text: String, edits: [Edit]) {
        var edits: [Edit] = []
        var tokens = tokenize(fixGlitches(text, &edits))
        guard !tokens.isEmpty else { return (text, []) }
        tokens = removeFillers(tokens, &edits)
        tokens = removeLikeFiller(tokens, &edits)
        tokens = removeFragments(tokens, &edits)
        tokens = collapseRepeats(tokens, &edits)
        return (tidy(tokens.map(\.text).joined(separator: " ")), edits)
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

    /// A few words either side of `range`, for the log.
    private static func near(_ tokens: [Token], _ range: Range<Int>) -> String {
        let lo = max(0, range.lowerBound - 3), hi = min(tokens.count, range.upperBound + 3)
        return tokens[lo..<hi].map(\.text).joined(separator: " ")
    }

    private static func note(_ kind: Edit.Kind, _ tokens: [Token], _ range: Range<Int>, _ edits: inout [Edit]) {
        edits.append(Edit(kind: kind, cut: tokens[range].map(\.text).joined(separator: " "), near: near(tokens, range)))
    }

    /// The recognizer writes "<unk>" for a sound it has no letter for. Between two letters that is
    /// an ampersand ("Q<unk>A"); anywhere else it is noise.
    static func fixGlitches(_ text: String, _ edits: inout [Edit]) -> String {
        guard text.contains("<unk>") else { return text }
        for word in text.split(whereSeparator: \.isWhitespace) where word.contains("<unk>") {
            edits.append(Edit(kind: .glitch, cut: "<unk>", near: String(word)))
        }
        return text
            .replacingOccurrences(of: #"(?<=\p{L})<unk>(?=\p{L})"#, with: "&", options: .regularExpression)
            .replacingOccurrences(of: #"\s*<unk>"#, with: "", options: .regularExpression)
    }

    static func removeFillers(_ input: [Token], _ edits: inout [Edit]) -> [Token] {
        var out: [Token] = []
        for (i, t) in input.enumerated() {
            guard fillers.contains(t.key) else { out.append(t); continue }
            note(.filler, input, i..<(i + 1), &edits)
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

    static func removeLikeFiller(_ input: [Token], _ edits: inout [Edit]) -> [Token] {
        var out: [Token] = []
        for (i, t) in input.enumerated() {
            if t.key == "like", t.hasComma, !t.endsSentence {
                let sentenceInitial = out.isEmpty || out[out.count - 1].endsSentence
                let afterComma = !out.isEmpty && out[out.count - 1].hasComma
                if sentenceInitial {                            // "Like, I think" → "I think"
                    note(.filler, input, i..<(i + 1), &edits)
                    continue
                }
                if afterComma {                                 // "and, like, Elijah" → "and Elijah"
                    note(.filler, input, i..<(i + 1), &edits)
                    out[out.count - 1].trail = out[out.count - 1].trail.replacingOccurrences(of: ",", with: "")
                    continue
                }
            }
            out.append(t)
        }
        return out
    }

    /// Drops the cut-off start of a word: "w white paper", "s within the folder", "sh really quickly".
    /// The recognizer writes these as a lone lowercase letter or two with no punctuation.
    static func removeFragments(_ input: [Token], _ edits: inout [Edit]) -> [Token] {
        var out: [Token] = []
        for (i, t) in input.enumerated() {
            if isFragment(input, at: i) { note(.fragment, input, i..<(i + 1), &edits) } else { out.append(t) }
        }
        return out
    }

    static func isFragment(_ tokens: [Token], at i: Int) -> Bool {
        let t = tokens[i]
        guard i + 1 < tokens.count, t.lead.isEmpty, t.trail.isEmpty, !t.core.isEmpty, t.core.count <= 3,
              t.core.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return false }
        let next = tokens[i + 1]
        guard !next.core.isEmpty, next.lead.isEmpty else { return false }
        // Spelling something out ("j i m m y"), or next to a number ("5 g", "v 2"): not a fragment.
        let neighbours = tokens[max(0, i - 2)..<min(tokens.count, i + 3)].enumerated().filter { $0.offset + max(0, i - 2) != i }.map(\.element)
        if neighbours.contains(where: \.isLoneLetter) { return false }
        if next.hasDigit || (i > 0 && tokens[i - 1].hasDigit) { return false }
        let known = fragmentLetters.contains(t.key) || fragmentStarts.contains(t.key)
        // The start of the very next word: "w white", "un unmirrored", "th the".
        if next.key.count > t.key.count, next.key.hasPrefix(t.key), known || !isWord(t.key) { return true }
        guard known else { return false }
        if i > 0, labelWords.contains(tokens[i - 1].key), !tokens[i - 1].endsSentence { return false }
        if compoundSeconds.contains(next.key) { return false }
        return true
    }

    /// Short everyday words, so "be because" or "in inside" are never read as a fragment and its word.
    private static func isWord(_ w: String) -> Bool {
        Glossary.CommonWords.contains(w) || stutterWords.contains(w)
    }

    static func collapseRepeats(_ input: [Token], _ edits: inout [Edit]) -> [Token] {
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
                    if n == 1 && !isStutter(first.first!) { continue }
                    // Keep the second copy (it carries the sentence on) and drop the first.
                    note(.repeat, tokens, (i - n)..<i, &edits)
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

    /// Whether one word said twice in a row is a stutter: only the small connecting words are.
    static func isStutter(_ first: Token) -> Bool { stutterWords.contains(first.key) }

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
                // "p.m." and "e.g." end in a period without ending the sentence.
                let abbreviation = c == "." && i >= 3 && chars[i - 2] == "." && chars[i - 1].isLetter && chars[i - 3].isLetter
                capitalizeNext = !abbreviation && (next.isWhitespace || "\"”)".contains(next))
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
