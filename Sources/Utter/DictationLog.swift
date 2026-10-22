import Foundation

/// A local, text-only record of every dictation, for harvesting new glossary words when Sean asks.
/// Never uploaded, never contains audio.
///
/// Two files in `~/Library/Application Support/Utter/`:
/// - `dictations.jsonl`: one line per dictation, and per thing Sean said to Utter (`kind: "command"`).
/// - `corrections.jsonl`: one line per dictation Sean fixed by hand in the panel. These pairs
///   are the best harvest material there is: exactly what the recognizer got wrong.
struct DictationLog {
    struct Entry: Codable {
        let time: Date
        let app: String?
        let raw: String
        let final: String
        let changes: [String]
        let audioSeconds: Double
        let waitSeconds: Double
        /// nil for a dictation; "command" for something Sean said to Utter.
        var kind: String? = nil
        /// For a command: what Utter did ("Added Jammy → Jimmy").
        var reply: String? = nil
        /// "copy" or "save" when the dictation wasn't pasted (Settings › After you release 🌐).
        var delivery: String? = nil
    }

    struct Correction: Codable {
        let time: Date
        /// The `time` of the dictation that was fixed.
        let dictation: Date
        let before: String
        let after: String
        let addedToGlossary: [String]
    }

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SpeechKey", isDirectory: true)
        // The app was called Utter until 2026-10-20: move its history over once.
        let old = base.appendingPathComponent("Utter", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: dir) }
        return dir
    }()
    static let file = directory.appendingPathComponent("dictations.jsonl")
    static let correctionsFile = directory.appendingPathComponent("corrections.jsonl")

    /// Off in test modes, so simulated runs don't land in Sean's history.
    var enabled = true

    func append(_ entry: Entry) { if enabled { Self.write(entry, to: Self.file) } }
    func append(_ correction: Correction) { if enabled { Self.write(correction, to: Self.correctionsFile) } }

    /// Every entry, oldest first, with hand corrections applied. Test runs are left out.
    static func all() -> [Entry] { recent(limit: .max) }

    /// The last `limit` entries, oldest first, with hand corrections applied.
    static func recent(limit: Int) -> [Entry] {
        let entries: [Entry] = (read(file) as [Entry]).filter { $0.app != "simulation" }.suffix(limit)
        let fixes: [Correction] = read(correctionsFile)
        guard !fixes.isEmpty else { return Array(entries) }
        var latest: [Date: String] = [:]
        for f in fixes { latest[f.dictation] = f.after }
        return entries.map { e in
            guard let after = latest[e.time] else { return e }
            return Entry(time: e.time, app: e.app, raw: e.raw, final: after, changes: e.changes,
                         audioSeconds: e.audioSeconds, waitSeconds: e.waitSeconds, kind: e.kind, reply: e.reply,
                         delivery: e.delivery)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            // Milliseconds, so a dictation's time works as its id.
            var c = encoder.singleValueContainer()
            try c.encode(isoFormatter.string(from: date))
        }
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = isoFormatter.date(from: s) ?? plainISOFormatter.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plainISOFormatter = ISO8601DateFormatter()

    static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var line = try encoder.encode(value)
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url)
            }
        } catch {
            NSLog("Speech Key: could not write \(url.lastPathComponent): \(error)")
        }
    }

    static func read<T: Decodable>(_ url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }
}
