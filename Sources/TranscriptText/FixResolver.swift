import Foundation

/// Works out what a spoken correction is about, using what was actually written recently.
///
/// The language model that reads the command only sees the command. When Sean says "the last thing
/// I did, it needs to be Marisol Tunney", the wrong spelling isn't in his words at all: it is in the
/// dictation from thirty seconds earlier ("Marigold Tenny"). The model used to make one up
/// ("Marisol Tuny"), and the app then answered that it had never written that (2026-11-26). So the
/// wrong word is looked up here, in the recent dictations, by what sounds most like the right one.
public enum FixResolver {
    public enum Decision: Equatable, Sendable {
        /// Add this fix.
        case add(heard: [String], correct: String)
        /// The glossary already writes `correct` when it hears `heard`.
        case alreadyFixed(heard: String, correct: String)
        /// The newest dictation already says it the right way, and nothing nearby looks like a miss.
        case alreadyRight(String)
        /// The right and wrong words came out the same; it needs spelling.
        case sameWord(String)
        /// No usable spelling in what was said.
        case missing
        /// Nothing like it was written recently.
        case unknown(String)
    }

    /// - Parameters:
    ///   - correct, wrong: what the model pulled out of the command.
    ///   - spelled: words spelled letter by letter in the command (uppercase).
    ///   - said: the command as transcribed.
    ///   - latest: the newest few dictations, newest first (as heard and as pasted).
    ///   - written: whether a word appears anywhere in the recent history.
    ///   - glossary: today's glossary.
    public static func decide(correct: String, wrong: [String], spelled: [String], said: String, latest: [String],
                              written: (String) -> Bool, glossary: Glossary) -> Decision {
        let right: String
        var named: [String] = []
        switch CommandWords.tidy(correct: spelledName(correct, spelled: spelled), wrong: wrong, spelled: spelled, said: said) {
        case .missing: return .missing
        case .sameWord(let w): right = w
        case .ok(let c, let w): right = c; named = w
        }
        // The same words in another case are only a miss for an acronym ("nova" → "NOVA"), not a name.
        let acronym = !right.contains(" ") && right.filter(\.isUppercase).count >= 2
        let hadNamed = !named.isEmpty
        // A wrong spelling has to sound something like the right one. The model also hands back
        // words that were merely nearby ("hey, you" for a name; "yes, pill" for a question).
        // Nor does a stumble over the right word itself ("Devon Devon" for "Devon").
        named = named.filter { (acronym || $0.lowercased() != right.lowercased()) && similarity($0, right) >= 0.3
            && !($0.contains(" ") && contains($0, right)) }
        // And it has to be real: written in a recent dictation, or said in this very command
        // ("it always transcribes it as lion").
        let seen = named.filter { written($0) || contains(said, $0) }
        if !seen.isEmpty {
            if seen.allSatisfy({ fixes(glossary, $0, to: right) }) { return .alreadyFixed(heard: seen[0], correct: right) }
            return .add(heard: seen, correct: right)
        }
        // Otherwise, the thing in the newest dictations that sounds most like the right word.
        if let miss = nearest(to: right, in: latest) {
            return fixes(glossary, miss, to: right) ? .alreadyFixed(heard: miss, correct: right) : .add(heard: [miss], correct: right)
        }
        if latest.prefix(2).contains(where: { contains($0, right) }) { return .alreadyRight(right) }
        return hadNamed ? .unknown(right) : .sameWord(right)
    }

    /// Whether the glossary already has this fix, as a row or in effect.
    static func fixes(_ glossary: Glossary, _ heard: String, to right: String) -> Bool {
        if glossary.apply(heard) == right { return true }
        return glossary.terms.contains { t in
            t.canonical == right && t.aliases.contains { $0.caseInsensitiveCompare(heard) == .orderedSame }
        }
    }

    /// A name spelled out with stops and starts ("DE-VON-Space MACEDA", from "D-E-V-O-N space
    /// M-A-C-E-D-A") as the name it spells: "Devon Maceda". Left alone when nothing was spelled.
    static func spelledName(_ correct: String, spelled: [String]) -> String {
        guard !spelled.isEmpty, correct.contains("-") || correct.range(of: "space", options: .caseInsensitive) != nil else { return correct }
        let parts = correct.replacingOccurrences(of: #"(?i)[-\s]*\bspace\b[-\s]*"#, with: " ", options: .regularExpression)
            .split(separator: " ").map { word -> String in
                let letters = word.filter { $0 != "-" }
                guard letters.allSatisfy({ $0.isUppercase }), letters.count > 1 else { return String(word) }
                return letters.prefix(1) + letters.dropFirst().lowercased()
            }
        return parts.joined(separator: " ")
    }

    /// How alike two spellings are by their letters, 0 to 1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = a.lowercased().filter { $0.isLetter || $0.isNumber }, y = b.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return 1 - Double(WordFacts.editDistance(x, y)) / Double(max(x.count, y.count))
    }

    /// The phrase in `texts` that sounds most like `target` without being it: same number of words,
    /// at least half the letters in common, and not made only of everyday words unless it is very close.
    static func nearest(to target: String, in texts: [String]) -> String? {
        let want = words(target)
        guard !want.isEmpty else { return nil }
        let goal = want.joined(separator: " ").lowercased()
        var best: (phrase: String, score: Double)?
        for text in texts {
            let have = words(text)
            guard have.count >= want.count else { continue }
            for i in 0...(have.count - want.count) {
                let phrase = have[i..<(i + want.count)].joined(separator: " ")
                let p = phrase.lowercased()
                guard p != goal else { continue }
                let score = 1 - Double(WordFacts.editDistance(p, goal)) / Double(max(p.count, goal.count))
                // Everyday words only count as a miss when they are nearly the same sound ("lion" for "Lyon").
                let everyday = have[i..<(i + want.count)].allSatisfy { WordFacts.isOrdinaryWord($0) && $0.first?.isLowercase == true }
                guard score >= (everyday ? 0.7 : 0.5) else { continue }
                if best == nil || score > best!.score { best = (phrase, score) }
            }
        }
        return best?.phrase
    }

    public static func contains(_ text: String, _ phrase: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase).replacingOccurrences(of: " ", with: "\\s+") + "(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)) }
            .map { $0.hasSuffix("'s") || $0.hasSuffix("’s") ? String($0.dropLast(2)) : $0 }
            .filter { !$0.isEmpty }
    }
}
