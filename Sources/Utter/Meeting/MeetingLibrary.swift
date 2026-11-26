import Foundation
import TranscriptText

/// A meeting's title, summary and snapshot count, in a hidden file in its folder
/// (`.speechkey-meeting.json`). The title is written by the on-device model, or by Sean with the
/// pencil, and then the model leaves it alone.
struct MeetingMeta: Codable, Equatable {
    var title: String?
    var summary: String?
    /// "agent" or "you".
    var titleBy: String?
    var snapshots: Int?
    var updated: Date?
    /// Times the on-device model failed to title it; after a few, older meetings aren't retried.
    var titleAttempts: Int?
    /// The voices in this meeting that can be given a name (everyone but "Me"), in the order they
    /// first spoke. nil until the transcript has been looked at. A name lives here and in this
    /// meeting's files only: nothing about a voice is kept, so nothing carries to another meeting.
    var voices: [Voice]?

    struct Voice: Codable, Equatable {
        /// The label the transcript was first written with: "Speaker 2" or "Them".
        var label: String
        /// The name the user gave; the files now say this in place of the label.
        var name: String?
        /// One sentence on what set this voice apart, written on the Mac to help recognize them.
        var about: String?
        /// What the files call this voice now.
        var shown: String { name ?? label }
    }

    static let fileName = ".speechkey-meeting.json"

    static func load(_ folder: URL) -> MeetingMeta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(MeetingMeta.self, from: data)
    }

    func save(to folder: URL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(self) else { return }
        try? data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Reads, changes and saves in one go.
    static func update(_ folder: URL, _ change: (inout MeetingMeta) -> Void) {
        var m = load(folder) ?? MeetingMeta()
        change(&m)
        m.updated = Date()
        m.save(to: folder)
    }
}

/// The saved meetings, newest first, for the panel's Meetings tab.
struct MeetingSummary: Identifiable, Equatable {
    let folder: URL
    let started: Date
    let parts: Int
    /// From the last part's file name ("part-04_28m31-51m57…" → 51:57).
    let length: TimeInterval?
    var title: String? = nil
    var summary: String? = nil
    var titleBy: String? = nil
    /// Snapshots, counting the part saved at the end (see `MeetingTranscript.snapshotCount`).
    /// Older meetings didn't store it, so their parts stand in.
    var snapshots: Int? = nil
    /// The voices that can be named (see `MeetingMeta.voices`).
    var voices: [MeetingMeta.Voice] = []
    var id: URL { folder }

    var snapshotCount: Int { snapshots ?? MeetingTranscript.snapshotCount(parts: parts) }

    /// The six-character code that ends the folder and every file name, for searching in Finder.
    var code: String? { MeetingNames.code(ofFolder: folder.lastPathComponent) }

    /// What opens when Sean clicks the meeting: the whole transcript if there is one.
    var mainFile: URL { MeetingLibrary.transcriptFile(folder) ?? folder }
}

enum MeetingLibrary {
    static func list(in root: URL, limit: Int = 1000) -> [MeetingSummary] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let summaries: [MeetingSummary] = folders.compactMap { folder in
            guard let started = startDate(folder.lastPathComponent) else { return nil }
            let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            let parts = files.filter(MeetingNames.isPart)
            let length = parts.compactMap(MeetingNames.partEnd).max()
            var meta = MeetingMeta.load(folder)
            // The first time a finished meeting is listed, note which voices it has (cheap, and kept).
            if meta?.voices == nil, !files.contains(MeetingRecovery.liveName), let found = scanVoices(folder) {
                MeetingMeta.update(folder) { $0.voices = found }
                meta = MeetingMeta.load(folder)
            }
            return MeetingSummary(folder: folder, started: started, parts: parts.count, length: length,
                                  title: meta?.title, summary: meta?.summary, titleBy: meta?.titleBy, snapshots: meta?.snapshots,
                                  voices: meta?.voices ?? [])
        }
        return Array(summaries.sorted { $0.started > $1.started }.prefix(limit))
    }

    // MARK: - Naming voices

    /// The voices in a meeting's transcript that can be named; nil if it has no transcript yet.
    static func scanVoices(_ folder: URL) -> [MeetingMeta.Voice]? {
        guard let file = transcriptFile(folder), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return MeetingVoicesFile.voices(text).map { MeetingMeta.Voice(label: $0) }
    }

    /// The transcript's paragraphs, for quotes and word counts.
    static func paragraphs(_ folder: URL) -> [MeetingVoicesFile.Paragraph] {
        guard let file = transcriptFile(folder), let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return MeetingVoicesFile.paragraphs(text)
    }

    enum Naming: Equatable { case named(String), unchanged, taken(String), notAName }

    /// Puts a name on one voice in every transcript file of this meeting (the whole transcript,
    /// the latest part and each part), or takes it off again when `name` is empty.
    @discardableResult
    static func nameVoice(_ folder: URL, label: String, as name: String) -> Naming {
        guard var meta = MeetingMeta.load(folder), let i = meta.voices?.firstIndex(where: { $0.label == label }) else { return .unchanged }
        let old = meta.voices![i].shown
        let wanted = name.trimmingCharacters(in: .whitespaces)
        let new: String
        if wanted.isEmpty || wanted == label { new = label } else {
            guard let usable = MeetingVoicesFile.usableName(wanted) else { return .notAName }
            new = usable
        }
        guard new != old else { return .unchanged }
        // Two voices with one name would merge in the files, and there'd be no telling them apart again.
        if meta.voices!.enumerated().contains(where: { $0.offset != i && $0.element.shown.caseInsensitiveCompare(new) == .orderedSame }) { return .taken(new) }
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        where MeetingNames.isFull(file) || MeetingNames.isLatest(file) || MeetingNames.isPart(file) {
            let url = folder.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let renamed = MeetingVoicesFile.renaming(text, from: old, to: new)
            if renamed != text { try? renamed.write(to: url, atomically: true, encoding: .utf8) }
        }
        meta.voices![i].name = new == label ? nil : new
        meta.updated = Date()
        meta.save(to: folder)
        UtterLog.write("meeting \(folder.lastPathComponent): a voice was \(new == label ? "un-named" : "named")")
        return .named(new)
    }

    /// "2026-10-22_1547" or "2026-10-22_1547_x7bm3z" → when the meeting started.
    static func startDate(_ folderName: String) -> Date? {
        guard folderName.count == 15 || MeetingNames.code(ofFolder: folderName) != nil else { return nil }
        return folderDate.date(from: String(folderName.prefix(15)))
    }

    /// The whole-meeting transcript (`full_<tag>.md`, or `full.md` in older folders), else the latest part.
    static func transcriptFile(_ folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let name = files.first(where: MeetingNames.isFull) ?? files.first(where: MeetingNames.isLatest)
        return name.map { folder.appendingPathComponent($0) }
    }

    /// The meeting's words for titling: the whole transcript if it exists, else every part in order.
    /// Timestamps are dropped ("**[12:34] Me:** hi" → "Me: hi"), since the model's context is small.
    static func transcriptText(_ folder: URL) -> String? {
        let fm = FileManager.default
        var text = transcriptFile(folder).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if text == nil {
            let parts = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter(MeetingNames.isPart).sorted()
            let joined = parts.compactMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
            text = joined.isEmpty ? nil : joined
        }
        guard let raw = text else { return nil }
        let speech = raw.components(separatedBy: "\n")
            .filter { $0.hasPrefix("**[") }
            .map { $0.replacingOccurrences(of: #"^\*\*\[[0-9:]+\] (\w+):\*\*"#, with: "$1:", options: .regularExpression) }
            .joined(separator: "\n")
        return speech.isEmpty ? nil : speech
    }

    /// Gives every older meeting a code: the folder becomes "2026-10-20_1157_k4p9xw", and the files
    /// Speech Key wrote in it end with that name too (`MeetingNames`). Files other tools put there
    /// are left alone, and so is a meeting that's still recording. Each file's first heading gets
    /// the code, so searching file contents finds it too. Returns old folder path → new.
    @discardableResult
    static func giveCodesToOlderMeetings(in root: URL) -> [String: String] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var taken = Set(folders.compactMap { MeetingNames.code(ofFolder: $0.lastPathComponent) })
        var moved: [String: String] = [:]
        for folder in folders where folder.lastPathComponent.count == 15 && startDate(folder.lastPathComponent) != nil {
            if fm.fileExists(atPath: folder.appendingPathComponent(MeetingRecovery.liveName).path) { continue }
            var code = MeetingNames.newCode()
            while taken.contains(code) { code = MeetingNames.newCode() }
            taken.insert(code)
            let tag = folder.lastPathComponent + "_" + code
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard let new = MeetingNames.renamed(name, tag: tag) else { continue }
                let url = folder.appendingPathComponent(name)
                if var text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("# Meeting "),
                   let end = text.firstIndex(of: "\n") {
                    text.insert(contentsOf: " · \(code)", at: end)
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                }
                try? fm.moveItem(at: url, to: folder.appendingPathComponent(new))
            }
            let target = root.appendingPathComponent(tag, isDirectory: true)
            do {
                try fm.moveItem(at: folder, to: target)
                moved[folder.path] = target.path
            } catch {
                UtterLog.write("couldn't rename \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !moved.isEmpty { UtterLog.write("gave codes to \(moved.count) older meetings") }
        return moved
    }

    static let folderDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
