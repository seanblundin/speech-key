import Foundation
import TranscriptText

/// Everything besides dictations that belongs in History: meetings starting and ending,
/// snapshots, and glossary changes. Text only, in `events.jsonl` next to the dictation log.
struct AppEvent: Codable, Equatable {
    enum Kind: String, Codable {
        case meetingStarted, meetingEnded, snapshot
        case glossaryAdded, glossaryRemoved, glossaryEdited
    }

    let time: Date
    let kind: Kind
    /// Meetings and snapshots: the meeting's folder.
    var folder: String? = nil
    /// Snapshots: the part file whose path was copied.
    var file: String? = nil
    var part: Int? = nil
    /// Snapshots: how far into the meeting. Meetings ended: how long it ran.
    var seconds: Double? = nil
    var snapshots: Int? = nil
    /// Glossary changes. For an edit, these are the new values and `old…` the previous ones.
    var heard: String? = nil
    var write: String? = nil
    var notes: String? = nil
    var oldHeard: String? = nil
    var oldWrite: String? = nil
    var oldNotes: String? = nil
    /// Where a glossary change came from: "voice" (Talk to Agent), "panel" (a fixed word),
    /// "tab" (the Glossary tab), or "undo".
    var source: String? = nil
}

struct EventLog {
    static let file = DictationLog.directory.appendingPathComponent("events.jsonl")

    /// Off in test modes, so simulated runs don't land in Sean's history.
    var enabled = true

    func append(_ event: AppEvent) { if enabled { DictationLog.write(event, to: Self.file) } }

    static func all() -> [AppEvent] { DictationLog.read(file) }

    /// Points events at meeting folders that were renamed (old folder path → new), and their files
    /// at the files' new names.
    static func remap(folders: [String: String]) {
        guard !folders.isEmpty else { return }
        let events: [AppEvent] = DictationLog.read(file)
        var changed = false
        let moved = events.map { e -> AppEvent in
            guard let old = e.folder, let new = folders[old] else { return e }
            var e = e
            e.folder = new
            if let f = e.file, f.hasPrefix(old + "/") {
                let name = String(f.dropFirst(old.count + 1))
                e.file = new + "/" + (MeetingNames.renamed(name, tag: URL(fileURLWithPath: new).lastPathComponent) ?? name)
            }
            changed = true
            return e
        }
        if changed { DictationLog.rewrite(moved, to: file) }
    }
}
