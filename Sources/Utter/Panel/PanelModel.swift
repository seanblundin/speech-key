import AppKit
import SpeechEngine

/// Everything the menu-bar panel shows and does. Three tabs (History, Meetings, Glossary) and a
/// gear for settings (Sean, 2026-10-21).
@MainActor
final class PanelModel: ObservableObject {
    enum Page: Hashable { case history, meetings, glossary, settings }
    /// The Glossary tab's order (Sean, 2026-10-22). Recent is the default.
    enum GlossarySort: Hashable { case recent, mostUsed, alphabetical }

    /// A hand fix waiting on "Add to your glossary?".
    struct GlossaryPrompt {
        struct Choice: Identifiable {
            let heard: String
            let correct: String
            var include = true
            /// Set when the heard word is everyday English, which the glossary treats carefully.
            let caution: String?
            /// The "heard" side is a name the glossary writes, so the fix starts unticked.
            var undoesGlossaryName = false
            var id: String { heard + "→" + correct }
        }
        let item: History.Item
        let newText: String
        var choices: [Choice]
    }

    /// What the panel can ask the rest of the app to do.
    struct Actions {
        var startMeeting: () -> Void = {}
        var endMeeting: () -> Void = {}
        var snapshot: () -> Void = {}
        var openMeetingsFolder: () -> Void = {}
        var openGlossary: () -> Void = {}
        var openLog: () -> Void = {}
        var showSetup: () -> Void = {}
        var setLaunchAtLogin: (Bool) -> Void = { _ in }
        var chooseGlossary: () -> Void = {}
        var chooseMeetingsFolder: () -> Void = {}
        var quit: () -> Void = {}
        var close: () -> Void = {}
    }

    struct Problem: Identifiable {
        let id: String
        let text: String
        let button: String
        let fix: () -> Void
    }

    @Published var page: Page = .history
    /// The dictation being edited (double-clicked), if any.
    @Published var editing: Date?
    /// The history row or meeting just copied, for its "Copied" tick.
    @Published var copied: Date?
    @Published var copiedMeeting: URL?
    @Published var meetingStartedAt: Date?
    @Published var meetings: [MeetingSummary] = []
    /// Meetings the agent is titling right now.
    @Published var titling: Set<URL> = []
    /// The meeting whose title is being typed.
    @Published var renaming: URL?
    @Published var prompt: GlossaryPrompt?
    @Published var toast: String?
    @Published var historySearch = ""
    @Published var glossarySearch = ""
    @Published var glossarySort: GlossarySort = .recent
    /// A row just made with "New", whose first field should take the cursor.
    @Published var focusGlossaryRow: UUID?
    @Published var isReady = true
    @Published var status = "Ready"
    @Published var statusColor: NSColor = .systemGreen
    @Published var problems: [Problem] = []
    @Published var brainStatus = ""
    @Published var launchAtLogin = false
    @Published var glossaryTermCount = 0
    /// Short forms of the two paths, like "~/Documents/Speech Key Meetings".
    @Published var glossaryPathLabel = ""
    @Published var meetingsPathLabel = ""

    let history: History
    let glossary: GlossaryStore
    var actions = Actions()
    var meetingsRoot: URL = MeetingController.root
    /// Meeting titles: the panel asks for one when Sean clears his own.
    var titler: MeetingTitler?
    private var toastWork: DispatchWorkItem?
    private var copiedWork: DispatchWorkItem?

    init(history: History, glossary: GlossaryStore) {
        self.history = history
        self.glossary = glossary
    }

    // MARK: - History

    /// History, filtered by the search field, grouped by day.
    var historyDays: [(day: String, items: [History.Item])] {
        let q = historySearch.trimmingCharacters(in: .whitespaces).lowercased()
        let items = q.isEmpty ? history.items : history.items.filter { $0.searchText.lowercased().contains(q) }
        return PanelFormat.byDay(items, date: \.time)
    }

    /// One click: copy, with a tick on the row.
    func copyItem(_ item: History.Item) {
        copy(item.text)
        tick(item.id)
    }

    /// A meeting or snapshot row: copy the file's path (ready to paste into Claude).
    func copyPath(_ path: String, for id: Date) {
        copy(path)
        tick(id)
    }

    private func tick(_ id: Date) {
        copied = id
        copiedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in if self?.copied == id { self?.copied = nil } }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    /// Return while editing: save and copy the new text, and if words were swapped, offer to remember them.
    func commit(_ item: History.Item, newText: String) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { editing = nil }
        guard !text.isEmpty, text != item.text else { return }
        history.setText(item.id, to: text)
        copy(text)
        let choices = CorrectionDiff.replacements(from: item.text, to: text).map { choice(heard: $0.heard, correct: $0.correct) }
        if choices.isEmpty {
            history.logCorrection(item.id, before: item.text, after: text, addedToGlossary: [])
            showToast("Saved and copied")
        } else {
            prompt = GlossaryPrompt(item: item, newText: text, choices: choices)
        }
    }

    func answerPrompt(add: Bool) {
        guard let p = prompt else { return }
        prompt = nil
        var added: [String] = []
        var failure: String?
        if add {
            for c in p.choices where c.include {
                do { try glossary.add(heard: [c.heard], correct: c.correct, source: .panel); added.append("\(c.heard) → \(c.correct)") }
                catch { failure = error.localizedDescription }
            }
        }
        history.logCorrection(p.item.id, before: p.item.text, after: p.newText, addedToGlossary: added)
        if let failure { showToast(failure) }
        else if added.isEmpty { showToast("Saved and copied") }
        else { showToast("Copied · added " + added.joined(separator: ", ") + " to your glossary") }
    }

    /// The Undo on a glossary row in History.
    func revert(_ event: AppEvent) {
        do {
            if let label = try glossary.revert(event) { showToast(label) } else { showToast("Already changed since then") }
        } catch { showToast(error.localizedDescription) }
    }

    /// A fix to offer. One that would undo a name the glossary writes starts unticked: Speech Key
    /// wrote that name on purpose, so remembering the fix would change it every time (Sean, 2026-10-21).
    func choice(heard: String, correct: String) -> GlossaryPrompt.Choice {
        guard glossary.rows.contains(where: { $0.write.caseInsensitiveCompare(heard) == .orderedSame }) else {
            return .init(heard: heard, correct: correct, caution: Self.caution(for: heard))
        }
        return .init(heard: heard, correct: correct, include: false,
                     caution: "“\(heard)” is a name in your glossary, so this would change it to “\(correct)” every time, even when you mean \(heard).",
                     undoesGlossaryName: true)
    }

    static func caution(for heard: String) -> String? {
        guard !heard.contains(" "), WordFacts.isOrdinaryWord(heard) else { return nil }
        return "“\(heard.lowercased())” is an everyday word, so Speech Key will only change it when it’s capitalized mid-sentence, like a name."
    }

    func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func showToast(_ text: String) {
        toastWork?.cancel()
        toast = text
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    // MARK: - Meetings

    func refreshMeetings() {
        meetings = MeetingLibrary.list(in: meetingsRoot)
        titling = titler?.working ?? []
    }

    func copyMeeting(_ m: MeetingSummary) {
        copy(m.mainFile.path)
        copiedMeeting = m.folder
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.copiedMeeting == m.folder { self?.copiedMeeting = nil }
        }
    }

    /// Sean's own title. An empty one hands the title back to the agent.
    func rename(_ m: MeetingSummary, to title: String) {
        renaming = nil
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != (m.title ?? "") else { return }
        MeetingMeta.update(m.folder) { meta in
            meta.title = t.isEmpty ? nil : t
            meta.titleBy = t.isEmpty ? nil : "you"
        }
        if t.isEmpty { titler?.title(m.folder) }
        refreshMeetings()
    }

    /// The title a meeting shows anywhere in the panel.
    func title(forFolder path: String?) -> String? {
        guard let path else { return nil }
        return meetings.first { $0.folder.path == path }?.title
    }

    // MARK: - Glossary tab

    /// The rows to show: filtered by the search field, in the chosen order. A blank row just made
    /// with New stays on top whatever the order.
    var glossaryRows: [GlossaryStore.Row] {
        let q = glossarySearch.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = q.isEmpty ? glossary.rows : glossary.rows.filter { r in
            r.isEmpty || [r.heard, r.write, r.notes].contains { $0.lowercased().contains(q) }
        }
        let place = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        let added = glossaryAddedAt
        // Rows added from Speech Key, newest first; the rest in the file's order.
        func newer(_ a: GlossaryStore.Row, _ b: GlossaryStore.Row) -> Bool {
            switch (added[a.write.lowercased()], added[b.write.lowercased()]) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return place[a.id]! < place[b.id]!
            }
        }
        let sorted: [GlossaryStore.Row]
        switch glossarySort {
        case .recent:
            sorted = rows.sorted(by: newer)
        case .mostUsed:
            let uses = glossaryUses
            sorted = rows.sorted { a, b in
                let ua = uses[a.write.lowercased()] ?? 0, ub = uses[b.write.lowercased()] ?? 0
                return ua != ub ? ua > ub : newer(a, b)
            }
        case .alphabetical:
            sorted = rows.sorted { a, b in
                let c = a.write.localizedCaseInsensitiveCompare(b.write)
                return c != .orderedSame ? c == .orderedAscending : place[a.id]! < place[b.id]!
            }
        }
        return sorted.filter(\.isEmpty) + sorted.filter { !$0.isEmpty }
    }

    /// How often each fix fired in the last 7 days, by its "Write as" (lowercased).
    var glossaryUses: [String: Int] {
        let since = Date().addingTimeInterval(-7 * 86_400)
        var uses: [String: Int] = [:]
        for item in history.items {
            guard item.time >= since else { break }   // newest first
            for fix in item.fixes {
                guard let to = fix.components(separatedBy: " → ").last else { continue }
                uses[to.lowercased(), default: 0] += 1
            }
        }
        return uses
    }

    /// When each fix was added from Speech Key (voice, a hand fix, or New), by its "Write as".
    private var glossaryAddedAt: [String: Date] {
        var at: [String: Date] = [:]
        for item in history.items {
            guard let e = item.event, e.kind == .glossaryAdded, let w = e.write?.lowercased(), at[w] == nil else { continue }
            at[w] = item.time
        }
        return at
    }

    func saveGlossaryRow(_ row: GlossaryStore.Row) {
        do { _ = try glossary.update(row) } catch { showToast(error.localizedDescription) }
    }

    func deleteGlossaryRow(_ id: UUID) {
        do { if let label = try glossary.delete(id) { showToast(label) } } catch { showToast(error.localizedDescription) }
    }
}
