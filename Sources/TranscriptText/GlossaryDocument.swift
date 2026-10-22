import Foundation

/// The glossary file as one table, Heard as | Write as | Notes (Sean, 2026-10-21), so the panel's
/// Glossary tab can edit it directly. Text above the table (title, goal) and sections below it
/// (spoken conventions) are kept exactly as written.
///
/// Older files used several two-column tables (`| Heard as | Correct |`) under headings, with
/// explanations in parentheses. `init(markdown:)` converts those on read; the converted text is
/// written back on the next save.
public struct GlossaryDocument: Equatable, Sendable {
    public struct Row: Identifiable, Sendable {
        public var id = UUID()
        /// Spellings the recognizer produces, comma separated. Empty: a name to listen for.
        public var heard: String
        /// What to write instead.
        public var write: String
        /// Anything else. A condition here ("only in book club talk") makes the fix need judgment;
        /// "unconfirmed" keeps the app from using the row at all.
        public var notes: String

        public init(heard: String, write: String, notes: String = "") {
            self.heard = heard
            self.write = write
            self.notes = notes
        }

        public var isEmpty: Bool { heard.isEmpty && write.isEmpty && notes.isEmpty }
    }

    public var preamble: String
    public var rows: [Row]
    public var postamble: String
    /// True when the text was converted from the older layout.
    public private(set) var wasConverted = false

    public static let header = "| Heard as | Write as | Notes |"
    public static let separator = "|---|---|---|"

    public static func == (a: GlossaryDocument, b: GlossaryDocument) -> Bool {
        a.markdown == b.markdown
    }

    public init(preamble: String, rows: [Row], postamble: String) {
        self.preamble = preamble
        self.rows = rows
        self.postamble = postamble
    }

    public init(markdown: String) {
        let lines = markdown.components(separatedBy: "\n")
        guard let h = lines.firstIndex(where: Self.isHeader) else {
            self = Self.converting(markdown)
            return
        }
        var i = h + 1
        if i < lines.count, Self.isSeparator(lines[i]) { i += 1 }
        var rows: [Row] = []
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            let cells = Self.cells(lines[i])
            if cells.count >= 2 { rows.append(Row(heard: cells[0], write: cells[1], notes: cells.count > 2 ? cells[2] : "")) }
            i += 1
        }
        preamble = lines[..<h].joined(separator: "\n") + (h > 0 ? "\n" : "")
        postamble = lines[i...].joined(separator: "\n")
        self.rows = rows
    }

    public var markdown: String {
        var out = preamble
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        out += Self.header + "\n" + Self.separator + "\n"
        for r in rows where !r.isEmpty {
            out += "| \(Self.clean(r.heard)) | \(Self.clean(r.write)) | \(Self.clean(r.notes)) |\n"
        }
        let rest = postamble.drop { $0 == "\n" }
        if !rest.isEmpty { out += "\n" + rest }
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: - Editing

    /// Adds a fix. Heard forms that pointed somewhere else move to this row, since a heard form
    /// claimed by two rows is never applied.
    public mutating func add(heard: [String], write: String, notes: String = "") {
        let heard = heard.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !heard.isEmpty, !write.isEmpty else { return }
        _ = remove(heardForms: heard, keepingWrite: write)
        if let i = rows.firstIndex(where: { $0.write == write && $0.notes == notes && !$0.heard.isEmpty }) {
            let existing = Self.list(rows[i].heard)
            let merged = existing + heard.filter { h in !existing.contains { $0.lowercased() == h.lowercased() } }
            rows[i].heard = merged.joined(separator: ", ")
        } else {
            rows.append(Row(heard: heard.joined(separator: ", "), write: write, notes: notes))
        }
    }

    /// Takes the given heard forms (or rows that write one of `words`) out. Returns what was removed.
    @discardableResult
    public mutating func remove(_ words: [String]) -> [Row] {
        let keys = Set(words.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        guard !keys.isEmpty else { return [] }
        var removed: [Row] = []
        var kept: [Row] = []
        for r in rows {
            let forms = Self.list(r.heard)
            if keys.contains(r.write.lowercased()), !forms.isEmpty {
                removed.append(r)
                continue
            }
            let gone = forms.filter { keys.contains($0.lowercased()) }
            if gone.isEmpty { kept.append(r); continue }
            removed.append(Row(heard: gone.joined(separator: ", "), write: r.write, notes: r.notes))
            let left = forms.filter { !keys.contains($0.lowercased()) }
            if !left.isEmpty { var r2 = r; r2.heard = left.joined(separator: ", "); kept.append(r2) }
        }
        rows = kept
        return removed
    }

    /// Removes heard forms from rows that write something other than `keepingWrite`.
    private mutating func remove(heardForms: [String], keepingWrite: String) -> [Row] {
        let keys = Set(heardForms.map { $0.lowercased() })
        var removed: [Row] = []
        rows = rows.compactMap { r in
            guard r.write != keepingWrite else { return r }
            let forms = Self.list(r.heard)
            let gone = forms.filter { keys.contains($0.lowercased()) }
            guard !gone.isEmpty else { return r }
            removed.append(Row(heard: gone.joined(separator: ", "), write: r.write, notes: r.notes))
            let left = forms.filter { !keys.contains($0.lowercased()) }
            guard !left.isEmpty else { return nil }
            var r2 = r
            r2.heard = left.joined(separator: ", ")
            return r2
        }
        return removed
    }

    // MARK: - Reading cells

    static func isHeader(_ line: String) -> Bool {
        let c = cells(line).map { $0.lowercased() }
        return c.count >= 3 && c[0] == "heard as" && c[1] == "write as"
    }

    static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.allSatisfy { "|-: ".contains($0) }
    }

    /// "| a | b | c |" → ["a", "b", "c"]
    static func cells(_ line: String) -> [String] {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return [] }
        var parts = t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// A cell can't hold a pipe or a line break.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func list(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Converting the older layout

    /// Two-column tables under headings become rows; headings that matter become notes
    /// ("Book club · Ana Ruiz, a member"); explanations in parentheses move to notes; the
    /// Unresolved table becomes rows noted "unconfirmed". Prose sections are kept below the table.
    static func converting(_ legacy: String) -> GlossaryDocument {
        var preamble: [String] = []
        var rows: [Row] = []
        var post: [String] = []
        var heading: String?
        var sectionProse: [String] = []
        var sectionHasTable = false
        var unresolved = false
        var started = false

        func closeSection() {
            guard let heading else { return }
            let prose = sectionProse.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            let meaningful = prose.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if meaningful, !(sectionHasTable && isIntro(prose.joined(separator: " "))) {
                post.append(heading)
                post.append("")
                post.append(contentsOf: prose)
                while post.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { post.removeLast() }
                post.append("")
            }
            sectionProse = []
            sectionHasTable = false
        }

        for raw in legacy.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                closeSection()
                started = true
                heading = line
                unresolved = line.lowercased().hasPrefix("## unresolved")
                continue
            }
            if !started {
                if line.lowercased().hasPrefix("format:") || line.lowercased().hasPrefix("| heard as") || isSeparator(line) { continue }
                if line.hasPrefix("|") {   // a table before any heading (the app's starter file)
                    if let r = convertRow(cells(line), section: nil, unresolved: false) { rows.append(r) }
                    continue
                }
                preamble.append(raw)
                continue
            }
            if line.hasPrefix("|") {
                sectionHasTable = true
                let c = cells(line)
                if c.isEmpty || c[0].lowercased() == "heard as" || isSeparator(line) { continue }
                if let r = convertRow(c, section: heading, unresolved: unresolved) { rows.append(r) }
                continue
            }
            if line.hasPrefix("Correct as usually transcribed:") {
                var list = String(line.dropFirst("Correct as usually transcribed:".count))
                var rest = ""
                if let r = list.range(of: ". ") { rest = String(list[r.upperBound...]); list = String(list[..<r.lowerBound]) }
                for name in list.split(separator: ",").map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }) where !name.isEmpty {
                    let paren = name.firstIndex(of: "(")
                    let spelling = paren.map { String(name[..<$0]).trimmingCharacters(in: .whitespaces) } ?? name
                    let inner = paren.map { String(name[$0...]).trimmingCharacters(in: CharacterSet(charactersIn: "() ")) } ?? ""
                    rows.append(Row(heard: "", write: spelling,
                                    notes: join([label(heading), inner, "usually transcribed right; listen for it"])))
                }
                if !rest.isEmpty { sectionProse.append(rest) }
                continue
            }
            sectionProse.append(raw)
        }
        closeSection()
        while preamble.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { preamble.removeLast() }
        var doc = GlossaryDocument(preamble: preamble.joined(separator: "\n") + "\n\n" + formatLine + "\n\n",
                                   rows: rows, postamble: post.joined(separator: "\n"))
        doc.wasConverted = true
        return doc
    }

    public static let formatLine = """
    Format: one row per fix. "Heard as" is what the transcript shows (several spellings separated by commas; leave it empty for a name to listen for). "Write as" is what to write. "Notes" can say when the fix applies ("only in book club talk"); a row whose notes start with "unconfirmed" is a guess and is never applied.
    """

    private static func convertRow(_ c: [String], section: String?, unresolved: Bool) -> Row? {
        guard c.count >= 2 else { return nil }
        let (heard, heardNote) = splitParens(c[0])
        if unresolved {
            let context = c.count > 2 ? c[2] : ""
            var guess = splitParens(c[1]).0
            for hedge in [", probably", " probably"] where guess.hasSuffix(hedge) { guess = String(guess.dropLast(hedge.count)) }
            let isSpelling = guess.split(separator: " ").count <= 3 && guess.first?.isUppercase == true
            return Row(heard: heard, write: isSpelling ? guess : heard,
                       notes: join(["unconfirmed", isSpelling ? "" : guess, context, heardNote]))
        }
        let correct = c[1]
        var write: String
        var correctNote: String
        if correct.lowercased().hasPrefix("correct as written") {
            write = heard
            correctNote = String(correct.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if let target = Glossary.Parser.extractTarget(heard: c[0], correct: correct) {
            write = target
            correctNote = remainder(of: correct, after: target)
            // "Trailblazers is the student founders club…": the whole sentence is the note.
            if correctNote.lowercased().hasPrefix("is ") { correctNote = correct }
        } else {
            // A long name with a note: "Riverside Community Food Bank (this year's beneficiary)".
            (write, correctNote) = splitParens(correct)
        }
        if write.isEmpty { write = correct }
        let quotes = CharacterSet(charactersIn: "\"“”")
        let cleanHeard = heard.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quotes) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
        return Row(heard: cleanHeard, write: write.trimmingCharacters(in: quotes), notes: join([label(section), heardNote, correctNote]))
    }

    /// "Dylan, Dana (when Daniel is in the room)" → ("Dylan, Dana", "when Daniel is in the room")
    static func splitParens(_ s: String) -> (String, String) {
        var notes: [String] = []
        let re = try! NSRegularExpression(pattern: #"\s*\(([^)]*)\)"#)
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) { notes.append(ns.substring(with: m.range(at: 1))) }
        let stripped = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return (stripped.trimmingCharacters(in: .whitespaces), notes.joined(separator: "; "))
    }

    /// "Tighe (Rory Tighe, leads the design studio)" after "Tighe" → "Rory Tighe, leads the design studio"
    static func remainder(of correct: String, after target: String) -> String {
        guard let r = correct.range(of: target) else { return "" }
        var rest = correct[r.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            let after = rest[rest.index(after: close)...].trimmingCharacters(in: CharacterSet(charactersIn: " .;,"))
            rest = after.isEmpty ? String(inner) : inner + ". " + after
        }
        return rest.trimmingCharacters(in: CharacterSet(charactersIn: " .;,"))
    }

    /// A heading worth keeping on each row: "## Book club (Thursday group)" → "Book club".
    static func label(_ heading: String?) -> String {
        guard var h = heading?.replacingOccurrences(of: "## ", with: "") else { return "" }
        h = splitParens(h).0
        let lower = h.lowercased()
        if lower == "people" || lower.hasPrefix("added from") || lower.hasPrefix("tools") { return "" }
        if let and = h.range(of: " and ") { h = String(h[..<and.lowerBound]) }
        return h
    }

    static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The short intro under "## Added from …", which means nothing once the rows have moved.
    private static func isIntro(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("move them into the right table") || t.hasPrefix("best guess and where it appeared")
    }
}
