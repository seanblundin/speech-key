import Foundation
import TranscriptText

/// Every change to the glossary goes through here: the Glossary tab's edits, words fixed in the
/// panel, and Talk to Agent. Each change can be undone, and each one is reported to History.
/// The file is one table (Heard as | Write as | Notes); an older file is converted on its first save.
@MainActor
final class GlossaryStore: ObservableObject {
    enum Source: String { case voice, panel, tab, undo }

    enum Failure: LocalizedError {
        case unreadable(String)
        case changedSince
        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "Couldn’t read the glossary: \(why)"
            case .changedSince: return "The glossary changed since then, so undo was skipped"
            }
        }
    }

    typealias Row = GlossaryDocument.Row

    private(set) var path: String
    /// The table, as the Glossary tab shows it.
    @Published private(set) var rows: [Row] = []
    /// What the next undo would take back, like "Added Jammy → Jimmy".
    @Published private(set) var undoLabel: String?
    /// Every change, for History.
    var onChange: ((AppEvent) -> Void)?

    private var undoStack: [(label: String, before: String, after: String)] = []

    init(path: String) {
        self.path = path
        refresh()
    }

    /// Settings picked another glossary file.
    func use(path new: String) {
        path = new
        undoStack.removeAll()
        undoLabel = nil
        refresh()
    }

    /// Re-reads the file. Rows that didn't change keep their identity, so a field being edited
    /// in the Glossary tab doesn't lose focus when the file is saved or edited elsewhere.
    func refresh() {
        guard let text = try? read() else { rows = []; return }
        var fresh = GlossaryDocument(markdown: text).rows
        var pool = rows
        for i in fresh.indices {
            if let j = pool.firstIndex(where: { $0.heard == fresh[i].heard && $0.write == fresh[i].write && $0.notes == fresh[i].notes }) {
                fresh[i].id = pool[j].id
                pool.remove(at: j)
            }
        }
        rows = fresh
    }

    // MARK: - Fixes from Talk to Agent and the panel

    /// Adds a fix. A heard form that pointed somewhere else moves to this row, since a heard form
    /// claimed by two rows is never applied. Returns what to tell Sean.
    @discardableResult
    func add(heard: [String], correct: String, source: Source = .voice) throws -> String {
        let heard = heard.filter { !$0.isEmpty && $0 != correct }
        guard !heard.isEmpty, !correct.isEmpty else { return "Nothing to add" }
        let before = try read()
        let current = Glossary(markdown: before)
        guard !heard.allSatisfy({ current.apply($0) == correct }) else {
            return "Already in your glossary: \(heard.joined(separator: ", ")) → \(correct)"
        }
        var doc = GlossaryDocument(markdown: before)
        doc.add(heard: heard, write: correct)
        let label = "Added \(heard.joined(separator: ", ")) → \(correct)"
        try write(doc, before: before, label: label)
        onChange?(AppEvent(time: Date(), kind: .glossaryAdded, heard: heard.joined(separator: ", "), write: correct,
                           source: source.rawValue))
        return label
    }

    /// Takes out fixes matching any of `words` (a heard form, or what a row writes).
    /// Returns what to tell Sean, or nil if nothing matched.
    func remove(_ words: [String], source: Source = .voice) throws -> String? {
        let before = try read()
        var doc = GlossaryDocument(markdown: before)
        let removed = doc.remove(words)
        guard !removed.isEmpty else { return nil }
        let label = "Removed " + removed.map { "\($0.heard) → \($0.write)" }.joined(separator: "; ")
        try write(doc, before: before, label: label)
        for r in removed {
            onChange?(AppEvent(time: Date(), kind: .glossaryRemoved, heard: r.heard, write: r.write, notes: r.notes,
                               source: source.rawValue))
        }
        return label
    }

    /// Takes back the last change, if the file hasn't been edited since ("undo that").
    func undo() throws -> String? {
        guard let last = undoStack.last else { return nil }
        guard try read() == last.after else { undoStack.removeAll(); undoLabel = nil; throw Failure.changedSince }
        undoStack.removeLast()
        try last.before.write(toFile: path, atomically: UtterPaths.glossaryWritesAtomically, encoding: .utf8)
        undoLabel = undoStack.last?.label
        refresh()
        return "Undid: \(last.label)"
    }

    /// Undoes one glossary change from History, by doing its opposite on today's file.
    func revert(_ e: AppEvent) throws -> String? {
        switch e.kind {
        case .glossaryAdded:
            let forms = (e.heard ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return try remove(forms, source: .undo)
        case .glossaryRemoved:
            guard let heard = e.heard, let write = e.write else { return nil }
            if heard.isEmpty { return try insert(Row(heard: "", write: write, notes: e.notes ?? ""), source: .undo) }
            let before = try read()
            var doc = GlossaryDocument(markdown: before)
            doc.rows.append(Row(heard: heard, write: write, notes: e.notes ?? ""))
            let label = "Put back \(heard) → \(write)"
            try self.write(doc, before: before, label: label)
            onChange?(AppEvent(time: Date(), kind: .glossaryAdded, heard: heard, write: write, notes: e.notes, source: Source.undo.rawValue))
            return label
        case .glossaryEdited:
            guard let row = rows.first(where: { $0.heard == (e.heard ?? "") && $0.write == (e.write ?? "") && $0.notes == (e.notes ?? "") })
            else { return nil }
            var old = row
            old.heard = e.oldHeard ?? ""
            old.write = e.oldWrite ?? ""
            old.notes = e.oldNotes ?? ""
            return try update(old, source: .undo)
        default:
            return nil
        }
    }

    // MARK: - The Glossary tab

    /// Saves one row's new values. Returns what to tell Sean, or nil if nothing changed.
    @discardableResult
    func update(_ row: Row, source: Source = .tab) throws -> String? {
        guard let i = rows.firstIndex(where: { $0.id == row.id }) else { return nil }
        let old = rows[i]
        let new = Row(heard: row.heard.trimmingCharacters(in: .whitespaces), write: row.write.trimmingCharacters(in: .whitespaces),
                      notes: row.notes.trimmingCharacters(in: .whitespaces))
        guard new.heard != old.heard || new.write != old.write || new.notes != old.notes else { return nil }
        let before = try read()
        var doc = GlossaryDocument(markdown: before)
        if old.isEmpty {
            // A new row from "New": it goes in at the top.
            guard !new.isEmpty else { return nil }
            doc.rows.insert(new, at: 0)
        } else {
            // The file is the truth: find the row there by its old contents.
            guard let j = doc.rows.firstIndex(where: { $0.heard == old.heard && $0.write == old.write && $0.notes == old.notes })
            else { refresh(); return nil }
            if new.isEmpty { doc.rows.remove(at: j) } else { doc.rows[j] = new }
        }
        let label = new.isEmpty ? "Removed \(old.heard) → \(old.write)" : "Saved \(new.heard.isEmpty ? new.write : "\(new.heard) → \(new.write)")"
        rows[i].heard = new.heard; rows[i].write = new.write; rows[i].notes = new.notes
        try write(doc, before: before, label: label)
        if old.isEmpty {
            onChange?(AppEvent(time: Date(), kind: .glossaryAdded, heard: new.heard, write: new.write, notes: new.notes, source: source.rawValue))
        } else if new.isEmpty {
            onChange?(AppEvent(time: Date(), kind: .glossaryRemoved, heard: old.heard, write: old.write, notes: old.notes, source: source.rawValue))
        } else {
            onChange?(AppEvent(time: Date(), kind: .glossaryEdited, heard: new.heard, write: new.write, notes: new.notes,
                               oldHeard: old.heard, oldWrite: old.write, oldNotes: old.notes, source: source.rawValue))
        }
        return label
    }

    /// A blank row at the top of the table, for the Glossary tab's "New". Not saved until it has words.
    func newRow() -> Row {
        let row = Row(heard: "", write: "", notes: "")
        rows.insert(row, at: 0)
        return row
    }

    /// Drops a blank row that was never filled in.
    func discardIfBlank(_ id: UUID) {
        if let i = rows.firstIndex(where: { $0.id == id }), rows[i].isEmpty { rows.remove(at: i) }
    }

    @discardableResult
    func delete(_ id: UUID) throws -> String? {
        guard let row = rows.first(where: { $0.id == id }) else { return nil }
        if row.isEmpty { discardIfBlank(id); return nil }
        var blank = row
        blank.heard = ""; blank.write = ""; blank.notes = ""
        return try update(blank)
    }

    private func insert(_ row: Row, source: Source) throws -> String? {
        let before = try read()
        var doc = GlossaryDocument(markdown: before)
        doc.rows.insert(row, at: 0)
        let label = "Put back \(row.write)"
        try write(doc, before: before, label: label)
        onChange?(AppEvent(time: Date(), kind: .glossaryAdded, heard: row.heard, write: row.write, notes: row.notes, source: source.rawValue))
        return label
    }

    // MARK: - File

    private func read() throws -> String {
        do { return try String(contentsOfFile: path, encoding: .utf8) } catch { throw Failure.unreadable(error.localizedDescription) }
    }

    private func write(_ doc: GlossaryDocument, before: String, label: String) throws {
        var text = doc.markdown
        // Keep the file's "Last edited" line honest.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        text = text.replacingOccurrences(of: #"\*Last edited: \d{4}-\d{2}-\d{2}\*"#, with: "*Last edited: \(f.string(from: Date()))*",
                                         options: .regularExpression)
        try text.write(toFile: path, atomically: UtterPaths.glossaryWritesAtomically, encoding: .utf8)
        undoStack.append((label, before, text))
        if undoStack.count > 20 { undoStack.removeFirst() }
        undoLabel = label
        refresh()
        UtterLog.write("glossary: \(label)")
    }
}
