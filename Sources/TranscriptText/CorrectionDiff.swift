import Foundation

/// What Sean changed when he fixed a dictation by hand, as "heard → correct" pairs that could
/// become glossary rows. Insertions and deletions on their own aren't mishearings, and long
/// rewrites aren't either, so only short replacements count.
public enum CorrectionDiff {
    public struct Replacement: Equatable, Sendable {
        public let heard: String
        public let correct: String
        public init(heard: String, correct: String) { self.heard = heard; self.correct = correct }
    }

    /// The longest phrase on either side that still counts as a mishearing.
    public static let maxWords = 4

    public static func replacements(from before: String, to after: String) -> [Replacement] {
        let a = words(before), b = words(after)
        // Longest common subsequence over words, then walk it to find the changed runs.
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Replacement] = []
        var i = 0, j = 0
        var removed: [String] = [], added: [String] = []
        func flush() {
            defer { removed = []; added = [] }
            guard !removed.isEmpty, !added.isEmpty, removed.count <= maxWords, added.count <= maxWords else { return }
            let r = Replacement(heard: removed.joined(separator: " "), correct: added.joined(separator: " "))
            if r.heard != r.correct, !out.contains(r) { out.append(r) }
        }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                flush(); i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                added.append(b[j]); j += 1
            } else {
                removed.append(a[i]); i += 1
            }
        }
        flush()
        return out
    }

    /// Words with surrounding punctuation stripped, so "Jammy," and "Jimmy." compare as names.
    static func words(_ s: String) -> [String] {
        let edges = CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "+&@#"))
        return s.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: edges) }
            .filter { !$0.isEmpty }
    }
}

/// Spoken spellings: "J I M M Y" or "J-I-M-M-Y" become one word. Used before Utter reads a
/// command, so "Jammy should be J I M M Y" means the exact letters.
public enum SpelledLetters {
    static let pattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}'’])\p{L}(?:[ \-.,]+\p{L}(?![\p{L}\p{N}])){2,}"#)

    /// Returns the text with each spelled run joined, plus the joined words (uppercase).
    public static func join(_ text: String) -> (text: String, words: [String]) {
        let ns = text as NSString
        var out = text
        var words: [String] = []
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let letters = ns.substring(with: m.range).filter(\.isLetter).uppercased()
            words.insert(letters, at: 0)
            out = (out as NSString).replacingCharacters(in: m.range, with: "\(letters) [spelled]")
        }
        return (out, words)
    }
}

/// Tidies the spellings a language model pulled out of a spoken glossary command.
public enum CommandWords {
    public enum Outcome: Equatable, Sendable {
        case ok(correct: String, wrong: [String])
        /// The model gave no usable spelling.
        case missing
        /// The right and wrong words came out the same ("Jammy should be Jammy"): the recognizer
        /// misheard the correct word too, so Sean needs to spell it.
        case sameWord(String)
    }

    public static func tidy(correct: String, wrong: [String], spelled: [String], said text: String) -> Outcome {
        let strip = CharacterSet(charactersIn: " .,;:!?\"“”'‘’[]")
        var correct = correct.replacingOccurrences(of: "[spelled]", with: "").trimmingCharacters(in: strip)
        guard !correct.isEmpty else { return .missing }
        // Spelled-out letters arrive in capitals; a name is meant unless Sean said otherwise.
        let saidCaps = text.range(of: #"\b(all caps|capitals|capital letters|uppercase|upper case)\b"#,
                                  options: [.regularExpression, .caseInsensitive]) != nil
        if !saidCaps, spelled.contains(correct.uppercased()), correct == correct.uppercased(), correct.count > 1 {
            correct = correct.prefix(1).uppercased() + correct.dropFirst().lowercased()
        }
        var seen = Set<String>()
        var clean: [String] = []
        var hadSame = false
        for w in wrong {
            let t = w.replacingOccurrences(of: "[spelled]", with: "").trimmingCharacters(in: strip)
            guard !t.isEmpty else { continue }
            // A capitalization-only variant counts only for terms with several capitals ("nova" → "NOVA").
            if t == correct || (t.lowercased() == correct.lowercased() && correct.filter(\.isUppercase).count < 2) { hadSame = true; continue }
            if seen.insert(t.lowercased()).inserted { clean.append(t) }
        }
        if clean.isEmpty {
            if hadSame { return .sameWord(correct) }
            // "Add NOVA, all caps": the lowercase form is what shows up wrong.
            if correct.filter(\.isUppercase).count >= 2 { return .ok(correct: correct, wrong: [correct.lowercased()]) }
            return .missing
        }
        return .ok(correct: correct, wrong: clean)
    }
}
