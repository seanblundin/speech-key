import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The user's names and terms, read from their glossary.md.
///
/// The file is written for Claude, so it mixes plain "heard as → correct" rows with rows that
/// need judgment ("London, only as a surname"). This type only acts on what is safe to do
/// mechanically:
/// - plain rows become whole-word replacements,
/// - rows with a condition contribute their correct spelling as a recognizer hint, nothing more,
/// - correct spellings also fix capitalization ("nova" → "NOVA"),
/// - a few spoken conventions from the file's prose section are hard-coded below.
public struct Glossary: @unchecked Sendable {
    /// A term the recognizer should favor, with the misspellings it tends to produce instead.
    public struct Term: Sendable, Hashable {
        public let canonical: String
        public let aliases: [String]
        public init(canonical: String, aliases: [String] = []) {
            self.canonical = canonical
            self.aliases = aliases
        }
    }

    /// One edit `apply` made, for showing Sean what changed.
    public struct Change: Sendable, Hashable, CustomStringConvertible {
        public let from: String
        public let to: String
        public var description: String { "\(from) → \(to)" }
    }

    /// Terms for recognizer boosting, most specific first.
    public let terms: [Term]

    /// A fix whose notes set a condition ("only in book club talk"). It is never applied
    /// mechanically; the app asks the on-device model whether the condition holds.
    public struct ConditionalRow: Sendable, Hashable {
        public let variants: [String]
        public let target: String
        public let note: String
    }

    /// A word in a dictation that one or more conditional rows could change.
    public struct ConditionalCandidate: Sendable {
        public let word: String
        public let options: [ConditionalRow]
    }

    public let conditionalRows: [ConditionalRow]

    private let replacements: [Rule]
    private let recasings: [Rule]
    private let conventions: [Rule]

    /// Correct spellings, for passing to the recognizer as hints.
    public var hints: [String] { terms.map(\.canonical) }

    /// Terms safe to hand to acoustic boosting. Short acronyms are left out: boosting matches
    /// by sound, and "MIT" or "TBD" sound like everyday words ("might", "TV") (seen 2026-10-18:
    /// "the room might not be booked" came back as "the room MIT not be booked").
    ///
    /// Only terms the recognizer is known to get wrong are boosted: rows with a recorded
    /// mishearing, or brand-style capitals (NOVA, NASA). Plain first names ("Luke", "Jack")
    /// are left out because they collide with ordinary words ("loop in" became "Luke and").
    public var boostTerms: [Term] {
        terms.filter { term in
            let t = term.canonical
            guard t.filter({ $0.isLetter || $0.isNumber }).count >= 4 else { return false }
            // Phrase rewrites ("venmoed" → "paid on Venmo") aren't names to listen for.
            guard let first = t.first, first.isUppercase || first.isNumber else { return false }
            if !t.contains(" "), CommonWords.isFirstName(t) { return false }
            let capitals = t.unicodeScalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
            return !term.aliases.isEmpty || capitals >= 2
        }
    }

    public static func load(path: String) throws -> Glossary {
        Glossary(markdown: try String(contentsOfFile: path, encoding: .utf8))
    }

    public static let empty = Glossary(markdown: "")

    public init(markdown: String) {
        let parsed = Parser.parse(markdown)
        self.terms = parsed.terms
        self.replacements = parsed.replacements
        self.recasings = parsed.recasings
        self.conditionalRows = parsed.conditional
        self.conventions = Self.spokenConventions
    }

    /// Words in `text` that a conditional row could change, each once, in order of appearance.
    public func conditionalCandidates(in text: String) -> [ConditionalCandidate] {
        var found: [(Int, String, [ConditionalRow])] = []
        var seen = Set<String>()
        let ns = text as NSString
        for row in conditionalRows {
            for v in row.variants {
                guard let re = try? NSRegularExpression(pattern: Parser.wordPattern(v), options: [.caseInsensitive]),
                      let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
                let word = ns.substring(with: m.range)
                guard word.lowercased() != row.target.lowercased() else { continue }
                if let i = found.firstIndex(where: { $0.1.lowercased() == word.lowercased() }) {
                    if !found[i].2.contains(row) { found[i].2.append(row) }
                } else if seen.insert(word.lowercased()).inserted {
                    found.append((m.range.location, word, [row]))
                }
            }
        }
        return found.sorted { $0.0 < $1.0 }.map { ConditionalCandidate(word: $0.1, options: $0.2) }
    }

    /// Replaces every whole-word `word` with `target`, for the conditional fixes the model approved.
    public static func applying(_ decisions: [(word: String, target: String)], to text: String) -> (text: String, changes: [Change]) {
        var out = text
        var changes: [Change] = []
        for d in decisions {
            guard let re = try? NSRegularExpression(pattern: Parser.wordPattern(d.word), options: [.caseInsensitive]) else { continue }
            let ns = out as NSString
            let n = re.numberOfMatches(in: out, range: NSRange(location: 0, length: ns.length))
            guard n > 0 else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: ns.length),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: d.target))
            changes.append(Change(from: d.word, to: d.target))
        }
        return (out, changes)
    }

    public func apply(_ text: String) -> String {
        applyWithChanges(text).text
    }

    public func applyWithChanges(_ text: String) -> (text: String, changes: [Change]) {
        var out = text
        var changes: [Change] = []
        for rule in conventions + replacements + recasings {
            out = rule.apply(to: out, changes: &changes)
        }
        var seen = Set<Change>()
        return (out, changes.filter { seen.insert($0).inserted })
    }

    // MARK: - Spoken conventions (from the glossary's "Spoken symbols and conventions" section)

    private static let spokenConventions: [Rule] = [
        // Spoken "dot" in a filename: "notes dot md" → "notes.md".
        Rule(regex: #"(?<![\p{L}\p{N}])([\p{L}\p{N}_-]+) dot (md|py|js|ts|tsx|jsx|json|txt|swift|html|css|csv|pdf|yaml|yml|sh|toml)(?![\p{L}\p{N}])"#,
             template: "$1.$2", lowercaseCaptureGroup: 2),
    ]

    // MARK: - Rule

    struct Rule {
        let regex: NSRegularExpression
        let replacement: String
        let isTemplate: Bool
        let lowercaseCaptureGroup: Int?
        /// For common English words: only act on a mid-sentence capitalized match,
        /// which is the recognizer saying "this is a name".
        let onlyCapitalizedMidSentence: Bool

        init(regex pattern: String, replacement: String, onlyCapitalizedMidSentence: Bool = false) {
            self.regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.replacement = replacement
            self.isTemplate = false
            self.lowercaseCaptureGroup = nil
            self.onlyCapitalizedMidSentence = onlyCapitalizedMidSentence
        }

        init(regex pattern: String, template: String, lowercaseCaptureGroup: Int? = nil) {
            self.regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.replacement = template
            self.isTemplate = true
            self.lowercaseCaptureGroup = lowercaseCaptureGroup
            self.onlyCapitalizedMidSentence = false
        }

        func apply(to text: String, changes: inout [Change]) -> String {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return text }
            let result = NSMutableString(string: text)
            for m in matches.reversed() {
                let original = ns.substring(with: m.range)
                if onlyCapitalizedMidSentence {
                    guard let first = original.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
                          !Self.isSentenceStart(ns, at: m.range.location) else { continue }
                }
                var new: String
                if isTemplate {
                    new = regex.replacementString(for: m, in: text, offset: 0, template: replacement)
                    if let g = lowercaseCaptureGroup, m.range(at: g).location != NSNotFound {
                        let cap = ns.substring(with: m.range(at: g))
                        new = new.replacingOccurrences(of: cap, with: cap.lowercased())
                    }
                } else {
                    new = replacement
                }
                guard new != original else { continue }
                result.replaceCharacters(in: m.range, with: new)
                changes.append(Change(from: original, to: new))
            }
            return result as String
        }

        static func isSentenceStart(_ text: NSString, at location: Int) -> Bool {
            var i = location - 1
            while i >= 0, let scalar = UnicodeScalar(text.character(at: i)), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                i -= 1
            }
            if i < 0 { return true }
            guard let scalar = UnicodeScalar(text.character(at: i)) else { return false }
            return ".!?\"“(".unicodeScalars.contains(scalar)
        }
    }

    // MARK: - Parser

    enum Parser {
        struct Output {
            var terms: [Term] = []
            var replacements: [Rule] = []
            var recasings: [Rule] = []
            var conditional: [ConditionalRow] = []
        }

        /// Rows whose meaning depends on context. They only contribute a hint.
        static let conditional = try! NSRegularExpression(
            pattern: #"\(when|\(as |\(only|context|mid-sentence|in a list|as an AI|as a surname"#, options: [.caseInsensitive])

        /// The same, for the Notes column of the one-table layout: a note that sets a condition.
        static let conditionalNote = try! NSRegularExpression(
            pattern: #"\b(only|when|if|unless)\b|\bcontext\b|mid-sentence|as a surname|in a list|as an ai\b|\bconfident"#,
            options: [.caseInsensitive])

        static func parse(_ markdown: String) -> Output {
            // Everything from "## Unresolved" on is guesses, not facts.
            let body = markdown.components(separatedBy: "\n## Unresolved").first ?? markdown
            var aliasesByTerm: [String: [String]] = [:]
            var order: [String] = []
            func addTerm(_ t: String) {
                if aliasesByTerm[t] == nil { aliasesByTerm[t] = []; order.append(t) }
            }
            var out = Output()
            // Heard forms that map to more than one spelling, or that appear in a conditional row,
            // need judgment ("Eli" is Elijah at work but Elias in book club). They are never auto-replaced.
            var targetsByVariant: [String: Set<String>] = [:]
            var conditionalVariants = Set<String>()
            var pending: [(variant: String, target: String)] = []
            // Every fix row, for working out which ones need judgment once all rows are read.
            var allRows: [(variants: [String], target: String, note: String)] = []

            for rawLine in body.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)

                if line.hasPrefix("Correct as usually transcribed:") {
                    var list = String(line.dropFirst("Correct as usually transcribed:".count))
                    if let r = list.range(of: ". ") { list = String(list[..<r.lowerBound]) }
                    for name in splitList(list) where isProperTerm(name) { addTerm(name) }
                    continue
                }

                guard let (heardCell, correctCell, notes) = tableCells(line) else { continue }
                // A guess, not a fact: never used.
                if notes.lowercased().hasPrefix("unconfirmed") { continue }
                guard let target = extractTarget(heard: heardCell.isEmpty ? correctCell : heardCell, correct: correctCell),
                      isProperTerm(target) else { continue }
                addTerm(target)
                // No heard form: a name to listen for, nothing to replace.
                if heardCell.isEmpty { continue }

                let rowIsConditional = matches(conditional, heardCell) || matches(conditional, correctCell)
                    || matches(conditionalNote, notes)
                let rowVariants = splitList(heardCell).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' ")) }
                    .filter { $0.count >= 2 && $0.lowercased() != target.lowercased() }
                allRows.append((rowVariants, target, notes.isEmpty ? correctCell : notes))
                for variant in splitList(heardCell) {
                    var v = variant.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' "))
                    // "the S team" → "S-Team" means the phrase after the article; keep the article.
                    for article in ["the ", "a ", "an "] where v.lowercased().hasPrefix(article) && !target.lowercased().hasPrefix(article) {
                        v = String(v.dropFirst(article.count))
                    }
                    guard v.count >= 2, v.lowercased() != target.lowercased() else { continue }
                    if rowIsConditional { conditionalVariants.insert(v.lowercased()); continue }
                    targetsByVariant[v.lowercased(), default: []].insert(target)
                    pending.append((v, target))
                }
            }

            // Rows that need judgment: a condition in the notes, or a heard form that two rows claim
            // ("Eli" is Elijah at work but Elias Moreno in book club). The app asks the on-device
            // model about these; it never applies them on its own.
            let judged = conditionalVariants.union(targetsByVariant.filter { $0.value.count > 1 }.keys)
            var seenRows = Set<ConditionalRow>()
            for row in allRows {
                let variants = row.variants.filter { judged.contains($0.lowercased()) }
                guard !variants.isEmpty else { continue }
                let c = ConditionalRow(variants: variants, target: row.target, note: row.note)
                if seenRows.insert(c).inserted { out.conditional.append(c) }
            }

            for (v, target) in pending {
                let key = v.lowercased()
                guard !conditionalVariants.contains(key), targetsByVariant[key]?.count == 1 else { continue }
                aliasesByTerm[target, default: []].append(v)
                let guarded = !v.contains(" ") && CommonWords.contains(v)
                out.replacements.append(Rule(regex: wordPattern(v), replacement: target, onlyCapitalizedMidSentence: guarded))
            }

            // Longest heard forms first, so "Luke Sorentos" wins over "Luke".
            out.replacements.sort { $0.regex.pattern.count > $1.regex.pattern.count }

            for term in order.sorted(by: { $0.count > $1.count }) {
                // Titlecase terms that are ordinary words ("beacon") keep their lowercase use.
                let upperCount = term.unicodeScalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
                if upperCount < 2, !term.contains(" "), CommonWords.contains(term) { continue }
                out.recasings.append(Rule(regex: flexiblePattern(term), replacement: term))
            }

            out.terms = order.map { Term(canonical: $0, aliases: aliasesByTerm[$0] ?? []) }
            return out
        }

        /// A table row as (heard, correct, notes). Heard may be empty in the one-table layout
        /// (a name to listen for). Header and separator rows return nil.
        static func tableCells(_ line: String) -> (String, String, String)? {
            guard line.hasPrefix("|") else { return nil }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4 else { return nil }
            let heard = cells[1], correct = cells[2]
            let notes = cells.count >= 5 ? cells[3] : ""
            if correct.isEmpty || heard.lowercased() == "heard as" { return nil }
            if heard.allSatisfy({ $0 == "-" || $0 == ":" }) && correct.allSatisfy({ $0 == "-" || $0 == ":" }) { return nil }
            if heard.isEmpty && cells.count < 5 { return nil }
            return (heard, correct, notes)
        }

        static func tableRow(_ line: String) -> (String, String)? {
            guard line.hasPrefix("|") else { return nil }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // "| a | b |" splits into ["", "a", "b", ""]
            guard cells.count >= 4 else { return nil }
            let heard = cells[1], correct = cells[2]
            if heard.isEmpty || correct.isEmpty || heard.lowercased() == "heard as" { return nil }
            if heard.allSatisfy({ $0 == "-" || $0 == ":" }) { return nil }
            return (heard, correct)
        }

        /// "NOVA (the team's AI hiring desk; written in capitals)" → "NOVA".
        static func extractTarget(heard: String, correct: String) -> String? {
            var t = correct
            for sep in [" (", ". ", "; ", ", "] {
                if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) }
            }
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:\"“”"))
            if t.split(separator: " ").count > 4 {
                // A description rather than a spelling, e.g. "Trailblazers is the student founders club…".
                let firstHeard = splitList(heard).first ?? heard
                if correct.lowercased().hasPrefix(firstHeard.lowercased() + " is ") { return firstHeard }
                return nil
            }
            return t.isEmpty ? nil : t
        }

        /// A name or acronym: has a capital letter or a digit. Rules out targets like "random".
        static func isProperTerm(_ t: String) -> Bool {
            t.count >= 2 && t.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) }
        }

        /// "A, B (note), C." → ["A", "B", "C"]
        static func splitList(_ s: String) -> [String] {
            let noParens = s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            return noParens.split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .\"“”")) }
                .filter { !$0.isEmpty }
        }

        static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
            re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }

        /// Whole words only. An apostrophe may follow ("Teegh's") but not precede ("'s team").
        static func wordPattern(_ phrase: String) -> String {
            let parts = phrase.split(whereSeparator: { $0 == " " || $0 == "-" }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            return #"(?<![\p{L}\p{N}'’-])"# + parts.joined(separator: #"[\s-]+"#) + #"(?![\p{L}\p{N}-])"#
        }

        /// Like wordPattern, but the parts may also run together: "S team", "S-Team", "STeam".
        static func flexiblePattern(_ term: String) -> String {
            let parts = term.split(whereSeparator: { $0 == " " || $0 == "-" }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            return #"(?<![\p{L}\p{N}'’-])"# + parts.joined(separator: #"[\s-]?"#) + #"(?![\p{L}\p{N}-])"#
        }
    }

    // MARK: - Common-word check

    enum CommonWords {
        static let words: Set<String> = {
            guard let s = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
            // Lowercase entries only: capitalized entries in web2 are proper nouns.
            return Set(s.split(separator: "\n").lazy.filter { $0.first?.isLowercase == true }.map(String.init))
        }()

        static func contains(_ w: String) -> Bool { words.contains(w.lowercased()) }

        static let firstNames: Set<String> = {
            guard let s = try? String(contentsOfFile: "/usr/share/dict/propernames", encoding: .utf8) else { return [] }
            return Set(s.split(separator: "\n").map { $0.lowercased() })
        }()

        static func isFirstName(_ w: String) -> Bool { firstNames.contains(w.lowercased()) }

        /// Every web2 entry, any case ("Friday" is ordinary too).
        static let allWords: Set<String> = {
            guard let s = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
            return Set(s.split(separator: "\n").map { $0.lowercased() })
        }()
    }
}

/// Whether words are ordinary English or a common first name, as opposed to a likely misspelled name.
public enum WordFacts {
    /// File extensions said out loud ("a dot md file"). They aren't names, so name boosting must leave them alone
    /// (seen 2026-10-21: "put it in a .md" came back with a glossary name that sounds like "md file").
    static let fileExtensions: Set<String> = ["md", "py", "js", "ts", "tsx", "jsx", "json", "txt", "swift", "html", "css",
                                               "csv", "pdf", "yaml", "yml", "sh", "toml"]

    public static func isOrdinaryWord(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: CharacterSet.letters.inverted)
        guard !w.isEmpty else { return true }
        let base = w.lowercased().hasSuffix("'s") || w.lowercased().hasSuffix("’s") ? String(w.dropLast(2)) : w
        if fileExtensions.contains(base.lowercased()) { return true }
        if Glossary.CommonWords.allWords.contains(base.lowercased()) || Glossary.CommonWords.isFirstName(base) { return true }
        return spelledCorrectly(base)
    }

    /// The system spell checker knows modern words ("demo", "email") that the old web2 list lacks.
    static func spelledCorrectly(_ word: String) -> Bool {
        #if canImport(AppKit)
        let range = NSSpellChecker.shared.checkSpelling(of: word.lowercased(), startingAt: 0, language: "en",
                                                        wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
        #else
        return false
        #endif
    }

    /// True when every word in the phrase is ordinary.
    public static func isOrdinary(_ phrase: String) -> Bool {
        phrase.split(whereSeparator: { $0 == " " || $0 == "-" }).allSatisfy { isOrdinaryWord(String($0)) }
    }
}

/// Adds rows to glossary.md in the "## Added from Speech Key" table, keeping the file parseable.
public enum GlossaryEditor {
    public static let sectionTitle = "## Added from Speech Key"
    /// The section's name before the app was renamed (2026-10-20). Still read, and renamed on the next write.
    static let legacyTitles = ["## Added from Utter", "## Added from SpeechKey"]

    static func isSectionTitle(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t == sectionTitle || legacyTitles.contains(t)
    }

    /// Returns `markdown` with a new `| heard | correct |` row, creating the section before
    /// "## Unresolved" (which the parser ignores) if needed, and bumping the *Last edited* date.
    public static func addingRow(heard: String, correct: String, to markdown: String, today: Date = Date()) -> String {
        let clean = { (s: String) in s.replacingOccurrences(of: "|", with: "/").trimmingCharacters(in: .whitespacesAndNewlines) }
        let row = "| \(clean(heard)) | \(clean(correct)) |"
        var lines = markdown.components(separatedBy: "\n")

        if let header = lines.firstIndex(where: { isSectionTitle($0) }) {
            lines[header] = sectionTitle
            // Append after the last table row of the section.
            var i = header + 1
            var lastRow = header
            while i < lines.count, !lines[i].hasPrefix("## ") {
                if lines[i].hasPrefix("|") { lastRow = i }
                i += 1
            }
            lines.insert(row, at: lastRow + 1)
        } else {
            let block = ["", sectionTitle, "", "Rows added from Speech Key (by fixing a word in its panel, or by voice). Move them into the right table when convenient.", "",
                         "| Heard as | Correct |", "|---|---|", row]
            if let unresolved = lines.firstIndex(where: { $0.hasPrefix("## Unresolved") }) {
                lines.insert(contentsOf: block + [""], at: unresolved)
            } else {
                lines.append(contentsOf: block)
            }
        }

        stampDate(&lines, today)
        return lines.joined(separator: "\n")
    }

    /// One row that `removing` changed, for telling Sean what happened.
    public struct Removal: Equatable, Sendable {
        /// The heard forms taken out.
        public let heard: [String]
        public let correct: String
        /// True when the whole row went; false when other heard forms are still in it.
        public let wholeRow: Bool
        public var description: String { "\(heard.joined(separator: ", ")) → \(correct)" }
    }

    /// Takes fixes out of the glossary. `words` are the spellings Sean named, on either side
    /// ("stop changing Jammy to Jimmy" and "remove Jimmy" both find `| Jammy | Jimmy |`).
    ///
    /// - Naming the correct spelling removes its whole row.
    /// - Naming only heard forms takes just those out; the row goes when none are left.
    /// - `keepingTarget`: rows for that spelling are left alone (used when adding, so a heard
    ///   form moves to its new row instead of being claimed by two).
    public static func removing(_ words: [String], from markdown: String, keepingTarget: String? = nil,
                                today: Date = Date()) -> (markdown: String, removed: [Removal]) {
        let wanted = Set(words.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return (markdown, []) }
        var lines = markdown.components(separatedBy: "\n")
        var removed: [Removal] = []
        var dropped = IndexSet()
        let end = lines.firstIndex(where: { $0.hasPrefix("## Unresolved") }) ?? lines.count

        for i in 0..<end {
            guard let (heardCell, correctCell) = Glossary.Parser.tableRow(lines[i].trimmingCharacters(in: .whitespaces)),
                  let target = Glossary.Parser.extractTarget(heard: heardCell, correct: correctCell) else { continue }
            if let keep = keepingTarget, keep.lowercased() == target.lowercased() { continue }
            let variants = Glossary.Parser.splitList(heardCell)
            let hit = variants.filter { wanted.contains($0.lowercased()) }
            let targetHit = wanted.contains(target.lowercased())
            if hit.isEmpty && !(targetHit && keepingTarget == nil) { continue }

            let remaining = variants.filter { !wanted.contains($0.lowercased()) }
            if targetHit && keepingTarget == nil || remaining.isEmpty {
                dropped.insert(i)
                removed.append(Removal(heard: variants, correct: target, wholeRow: true))
            } else {
                // Keep any condition on the heard side ("(when Daniel is in the room)").
                let ns = heardCell as NSString
                let notes = Self.parenthetical.matches(in: heardCell, range: NSRange(location: 0, length: ns.length))
                    .map { ns.substring(with: $0.range) }
                lines[i] = "| \(([remaining.joined(separator: ", ")] + notes).joined(separator: " ")) | \(correctCell) |"
                removed.append(Removal(heard: hit, correct: target, wholeRow: false))
            }
        }
        guard !removed.isEmpty else { return (markdown, []) }
        for i in dropped.reversed() { lines.remove(at: i) }
        stampDate(&lines, today)
        return (lines.joined(separator: "\n"), removed)
    }

    private static let parenthetical = try! NSRegularExpression(pattern: #"\([^)]*\)"#)

    private static func stampDate(_ lines: inout [String], _ today: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let i = lines.firstIndex(where: { $0.hasPrefix("*Last edited:") }) {
            lines[i] = "*Last edited: \(formatter.string(from: today))*"
        }
    }

    /// The rows in the "Added from Speech Key" section, newest last.
    public static func utterRows(in markdown: String) -> [(heard: String, correct: String)] {
        let lines = markdown.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { isSectionTitle($0) }) else { return [] }
        var rows: [(String, String)] = []
        for line in lines[(header + 1)...] {
            if line.hasPrefix("## ") { break }
            if let row = Glossary.Parser.tableRow(line.trimmingCharacters(in: .whitespaces)) { rows.append(row) }
        }
        return rows
    }
}
