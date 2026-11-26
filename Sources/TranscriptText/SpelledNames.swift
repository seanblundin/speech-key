import Foundation

/// Names learned from an ordinary dictation: say a name and spell it in the same sentence
/// ("Sara S-A-R-A-H", or "my friend Sara is coming, S-A-R-A-H"), and the spelling is what to
/// write from now on.
///
/// One narrow rule on purpose. Sentences that talk about a mistake ("you wrote X instead of Y",
/// "mistranscribed as…") are left alone: telling right from wrong there takes understanding,
/// and Apple's on-device model got 2 of Sean's 6 real ones backwards (tested 2026-11-18).
public enum SpelledNames {
    public struct Lesson: Equatable, Sendable {
        /// How the recognizer wrote the name.
        public let heard: String
        /// The spelling Sean gave.
        public let write: String
    }

    /// Capital letters said one at a time: "S-A-R-A-H" or "K A Y".
    static let run = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}\-])\p{Lu}(?:[\- ]\p{Lu}){2,}(?![\p{L}\p{N}\-])"#)
    /// A sentence with one of these is about a mistake, where the spelled word may be the wrong one.
    static let aboutAMistake = try! NSRegularExpression(
        pattern: #"\b(\w*transcri\w*|misspell\w*|misheard|instead of|rather than|typo|wrote|written|heard|wrong|not|should be|supposed to be)\b"#,
        options: [.caseInsensitive])
    public static func lessons(in text: String) -> [Lesson] {
        let ns = text as NSString
        var out: [Lesson] = []
        for m in run.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let letters = ns.substring(with: m.range).filter(\.isLetter)
            guard letters.count >= 3, Set(letters).count > 1 else { continue }          // "I I I" is a stutter
            let write = letters.prefix(1).uppercased() + letters.dropFirst().lowercased()
            // An everyday word spelled out is something to type ("make it say S-A-L-E"), not a name.
            if Glossary.CommonWords.contains(write), !Glossary.CommonWords.isFirstName(write) { continue }

            // The sentence around the run.
            let before = ns.substring(to: m.range.location)
            let after = ns.substring(from: m.range.location + m.range.length)
            let head = before.components(separatedBy: CharacterSet(charactersIn: ".!?")).last ?? before
            let tail = after.components(separatedBy: CharacterSet(charactersIn: ".!?")).first ?? ""
            let sentence = head + " " + tail
            if aboutAMistake.firstMatch(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length)) != nil { continue }

            // The name as it was heard: the nearest word in the sentence that sounds like the spelling,
            // looking back first ("My friend Anemonee is a good friend of mine, A-N-I-E-M-O-N-E",
            // Sean's own test on 2026-11-26), then ahead.
            func words(_ part: String) -> [String] {
                part.split(whereSeparator: { $0.isWhitespace })
                    .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
                    .map { $0.hasSuffix("'s") || $0.hasSuffix("’s") ? String($0.dropLast(2)) : $0 }
                    .filter { !$0.isEmpty }
            }
            let behind = words(head), ahead = words(tail)
            if (behind + ahead).contains(where: { $0.caseInsensitiveCompare(write) == .orderedSame }) { continue }   // already right
            guard let heard = behind.reversed().first(where: { soundsLike($0, write) }) ?? ahead.first(where: { soundsLike($0, write) })
            else { continue }
            let lesson = Lesson(heard: heard, write: write)
            if !out.contains(lesson) { out.append(lesson) }
        }
        return out
    }

    /// Close enough to be the same name written another way, and not an everyday word.
    static func soundsLike(_ heard: String, _ write: String) -> Bool {
        let h = heard.lowercased(), w = write.lowercased()
        // The recognizer writes names with a capital; "the" before T-H-E-O is not a misheard Theo.
        guard h.count >= 3, h != w, heard.first?.isUppercase == true, !CleanVerbatim.stutterWords.contains(h),
              h.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return false }
        if Glossary.CommonWords.contains(h), !Glossary.CommonWords.isFirstName(h) { return false }
        let d = WordFacts.editDistance(h, w)
        return d <= 2 || (h.first == w.first && d <= max(2, (w.count + 1) / 2))
    }

    /// Writes the lesson into text that still has the heard form.
    public static func apply(_ lesson: Lesson, to text: String) -> String {
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: lesson.heard) + #"(?![\p{L}\p{N}])"#
        return text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: lesson.write), options: .regularExpression)
    }
}
