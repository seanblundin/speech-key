import Foundation

/// Which words of the raw transcript didn't make it into the cleaned text, so History's raw view
/// can point at them.
public enum RawDiff {
    /// Ranges (in `raw`, as NSRange) of the words that are only in the raw text.
    public static func onlyInRaw(raw: String, cleaned: String) -> [NSRange] {
        let rawWords = words(raw), cleanWords = words(cleaned)
        let diff = cleanWords.map(\.key).difference(from: rawWords.map(\.key))
        var ranges: [NSRange] = []
        for change in diff {
            if case .remove(let offset, _, _) = change { ranges.append(rawWords[offset].range) }
        }
        return ranges.sorted { $0.location < $1.location }
    }

    /// Whether the cleanup changed anything worth showing (more than spacing or a capital).
    public static func differs(raw: String, cleaned: String) -> Bool {
        words(raw).map(\.key) != words(cleaned).map(\.key)
    }

    /// Whitespace-separated words with their ranges; the key ignores case and punctuation, so
    /// "Um," matches "um" and "Q<unk>A" differs from "Q&A" as a whole.
    private static func words(_ text: String) -> [(key: String, range: NSRange)] {
        let ns = text as NSString
        var out: [(String, NSRange)] = []
        let pattern = try! NSRegularExpression(pattern: #"\S+"#)
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
            if !key.isEmpty { out.append((key, m.range)) }
        }
        return out
    }
}
