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
    /// From the last part's file name ("part-04_28m31-51m57.md" → 51:57).
    let length: TimeInterval?
    var title: String? = nil
    var summary: String? = nil
    var titleBy: String? = nil
    /// Snapshots, counting the part saved at the end (see `MeetingTranscript.snapshotCount`).
    /// Older meetings didn't store it, so their parts stand in.
    var snapshots: Int? = nil
    var id: URL { folder }

    var snapshotCount: Int { snapshots ?? MeetingTranscript.snapshotCount(parts: parts) }

    /// What opens when Sean clicks the meeting: the whole transcript if there is one.
    var mainFile: URL {
        let fm = FileManager.default
        for name in ["full.md", "latest.md"] {
            let url = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return folder
    }
}

enum MeetingLibrary {
    static func list(in root: URL, limit: Int = 1000) -> [MeetingSummary] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let summaries: [MeetingSummary] = folders.compactMap { folder in
            guard let started = folderDate.date(from: folder.lastPathComponent) else { return nil }
            let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            let parts = files.filter { $0.hasPrefix("part-") && $0.hasSuffix(".md") }
            let length = parts.compactMap(endSeconds).max()
            let meta = MeetingMeta.load(folder)
            return MeetingSummary(folder: folder, started: started, parts: parts.count, length: length,
                                  title: meta?.title, summary: meta?.summary, titleBy: meta?.titleBy, snapshots: meta?.snapshots)
        }
        return Array(summaries.sorted { $0.started > $1.started }.prefix(limit))
    }

    /// "part-04_28m31-51m57.md" → 3117.
    static func endSeconds(_ name: String) -> TimeInterval? {
        guard let dash = name.lastIndex(of: "-"), let dot = name.lastIndex(of: ".") else { return nil }
        let stamp = name[name.index(after: dash)..<dot]   // "51m57"
        let bits = stamp.split(separator: "m")
        guard bits.count == 2, let m = Double(bits[0]), let s = Double(bits[1]) else { return nil }
        return m * 60 + s
    }

    /// The meeting's words for titling: the whole transcript if it exists, else every part in order.
    /// Timestamps are dropped ("**[12:34] Me:** hi" → "Me: hi"), since the model's context is small.
    static func transcriptText(_ folder: URL) -> String? {
        let fm = FileManager.default
        var text: String?
        for name in ["full.md", "latest.md"] {
            if let t = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) { text = t; break }
        }
        if text == nil {
            let parts = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("part-") }.sorted()
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

    static let folderDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
