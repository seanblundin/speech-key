import AppKit
import TranscriptText

/// Everything that happened in Speech Key, newest first: dictations, conversations with the
/// agent (⇧ fn), meetings, snapshots and glossary changes (Sean, 2026-10-21: "a full history you
/// power scroll through"). All of it is kept, as text, and loaded once so the panel opens instantly.
@MainActor
final class History: ObservableObject {
    enum Kind: Equatable {
        case dictation
        case command
        case event(AppEvent.Kind)
    }

    struct Item: Identifiable, Equatable {
        /// When it happened; also its id in the log files.
        let time: Date
        let kind: Kind
        let app: String?
        var text: String
        /// Glossary fixes made automatically, like "Tieg → Tighe".
        let fixes: [String]
        /// For a command: what the agent did or said.
        var reply: String?
        /// "copy" or "save" when a dictation wasn't pasted.
        var delivery: String?
        var event: AppEvent?
        var id: Date { time }

        var isCommand: Bool { kind == .command }
        var isDictation: Bool { kind == .dictation }

        /// Text to match against the search field.
        var searchText: String {
            var bits = [text, reply ?? "", app ?? ""]
            if let e = event { bits += [e.heard ?? "", e.write ?? "", e.notes ?? "", e.file ?? ""] }
            return bits.joined(separator: " ")
        }
    }

    @Published private(set) var items: [Item] = []   // newest first
    private let log: DictationLog
    let events: EventLog

    init(log: DictationLog, events: EventLog = EventLog(), loadFromDisk: Bool = true) {
        self.log = log
        self.events = events
        guard loadFromDisk else { return }
        let all = DictationLog.all().map(Self.item) + EventLog.all().map(Self.item)
        items = all.sorted { $0.time > $1.time }
    }

    func add(_ entry: DictationLog.Entry) { insert(Self.item(entry)) }

    /// Records a meeting, snapshot or glossary change, on disk and on screen.
    func record(_ event: AppEvent) {
        events.append(event)
        insert(Self.item(event))
    }

    private func insert(_ item: Item) {
        let i = items.firstIndex { $0.time < item.time } ?? items.count
        items.insert(item, at: i)
    }

    /// Shows Sean's hand fix right away; `logCorrection` records it once the glossary question is answered.
    func setText(_ id: Date, to text: String) {
        guard let i = items.firstIndex(where: { $0.id == id && $0.isDictation }) else { return }
        items[i].text = text
    }

    /// Records a hand fix, so the harvest sees exactly what the recognizer got wrong.
    func logCorrection(_ id: Date, before: String, after: String, addedToGlossary: [String]) {
        log.append(DictationLog.Correction(time: Date(), dictation: id, before: before, after: after,
                                           addedToGlossary: addedToGlossary))
    }

    /// For design review and tests.
    func replaceAll(_ new: [Item]) { items = new.sorted { $0.time > $1.time } }

    private static func item(_ e: DictationLog.Entry) -> Item {
        Item(time: e.time, kind: e.kind == "command" ? .command : .dictation, app: e.app,
             text: e.final.trimmingCharacters(in: .whitespaces), fixes: e.changes, reply: e.reply, delivery: e.delivery)
    }

    private static func item(_ e: AppEvent) -> Item {
        Item(time: e.time, kind: .event(e.kind), app: nil, text: "", fixes: [], reply: nil, delivery: nil, event: e)
    }
}
