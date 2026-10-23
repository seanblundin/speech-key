import Foundation

/// The text side of meeting mode: lines from two streams ("Me" and "Them"), cut into snapshot parts.
///
/// Rules from MEETING-MODE.md (Sean prefers simple and systematic over clever):
/// - Part 1 starts at 0:00. Every later part starts a fixed 10 s before the previous part ended.
/// - Files are named `part-02_12m30-27m05.md` (elapsed time, so the overlap shows in the name).
/// - `full_<tag>.md` holds everything so far; `latest_<tag>.md` is a copy of the newest part
///   (names in `MeetingNames`).
public struct MeetingTranscript: Sendable {
    public struct Line: Sendable, Equatable {
        public let speaker: String
        /// Seconds since the meeting started.
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String
        public init(speaker: String, start: TimeInterval, end: TimeInterval, text: String) {
            self.speaker = speaker
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public static let me = "Me"
    public static let them = "Them"
    public static let overlap: TimeInterval = 10

    /// The meeting's folder name ("2026-10-22_1547_x7bm3z"), ending every file name; and its
    /// short code, shown in each file's heading so a search for it finds the files' text too.
    public var tag: String?
    public var code: String?

    public let startedAt: Date
    public private(set) var lines: [Line] = []
    /// Where each saved part ended, in seconds since the start.
    public private(set) var partEnds: [TimeInterval] = []

    public init(startedAt: Date) { self.startedAt = startedAt }

    /// Rebuilds a transcript from a crash-recovery log.
    public init(startedAt: Date, lines: [Line], partEnds: [TimeInterval]) {
        self.startedAt = startedAt
        self.partEnds = partEnds
        for l in lines { add(l) }
    }

    /// How many snapshots a finished meeting counts: the part saved at the end is one, unless it is
    /// the only part, which is just the whole meeting. So 0, 2, 3… never 1 (Sean, 2026-10-21).
    public static func snapshotCount(parts: Int) -> Int { parts <= 1 ? 0 : parts }

    /// End of the last line, a fair estimate of how long a recovered meeting ran.
    public var lastLineEnd: TimeInterval { lines.map(\.end).max() ?? 0 }

    public mutating func add(_ line: Line) {
        guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Keep time order; chunks from the two streams finish out of order.
        let i = lines.lastIndex(where: { $0.start <= line.start }).map { $0 + 1 } ?? 0
        lines.insert(line, at: i)
    }

    /// The window the next part covers if it ends at `end`.
    public func nextPartWindow(endingAt end: TimeInterval) -> (start: TimeInterval, end: TimeInterval) {
        let start = partEnds.last.map { max(0, $0 - Self.overlap) } ?? 0
        return (start, max(end, start))
    }

    /// Records a part ending at `end` and returns its file name and contents.
    public mutating func makePart(endingAt end: TimeInterval) -> (number: Int, fileName: String, markdown: String) {
        let window = nextPartWindow(endingAt: end)
        partEnds.append(window.end)
        let number = partEnds.count
        let name = MeetingNames.part(number, start: window.start, end: window.end, tag: tag)
        var md = "# Meeting \(Self.dateTime(startedAt)), part \(number)\(code.map { " · \($0)" } ?? "")\n\n"
        md += "\(Self.clock(window.start))–\(Self.clock(window.end)) into the call"
        if number > 1 { md += ", starting \(Int(Self.overlap)) s before part \(number - 1) ended" }
        md += ".\n\n"
        md += Self.render(linesIn(window.start, window.end))
        return (number, name, md)
    }

    /// The whole meeting so far.
    public func fullMarkdown(now: TimeInterval) -> String {
        var md = "# Meeting \(Self.dateTime(startedAt))\(code.map { " · \($0)" } ?? "")\n\n"
        md += "Length \(Self.clock(now)) · \(partEnds.count) part\(partEnds.count == 1 ? "" : "s") saved\n\n"
        md += Self.render(lines)
        return md
    }

    func linesIn(_ start: TimeInterval, _ end: TimeInterval) -> [Line] {
        lines.filter { $0.end > start && $0.start < end }
    }

    /// One paragraph per turn: consecutive lines from the same speaker are joined.
    /// "Me" lines that repeat what "Them" said at the same moment are dropped: on laptop speakers
    /// the mic hears the call too.
    static func render(_ lines: [Line]) -> String {
        let kept = dropEcho(lines)
        var out: [String] = []
        var current: (speaker: String, start: TimeInterval, texts: [String])?
        for line in kept {
            if let c = current, c.speaker == line.speaker {
                current?.texts.append(line.text)
            } else {
                if let c = current { out.append("**[\(clock(c.start))] \(c.speaker):** \(c.texts.joined(separator: " "))") }
                current = (line.speaker, line.start, [line.text])
            }
        }
        if let c = current { out.append("**[\(clock(c.start))] \(c.speaker):** \(c.texts.joined(separator: " "))") }
        return out.isEmpty ? "_Nothing transcribed yet._\n" : out.joined(separator: "\n\n") + "\n"
    }

    static func dropEcho(_ lines: [Line]) -> [Line] {
        let them = lines.filter { $0.speaker == Self.them }
        return lines.filter { line in
            guard line.speaker == Self.me else { return true }
            let mine = words(line.text)
            guard !mine.isEmpty else { return true }
            for t in them where t.end > line.start - 3 && t.start < line.end + 3 {
                let theirs = Set(words(t.text))
                let shared = mine.filter { theirs.contains($0) }.count
                // Longer lines: mostly the same words. Short lines ("that worked", "typical clients"):
                // every word, since a couple of shared words is otherwise just conversation.
                let isEcho = mine.count >= 4 ? Double(shared) / Double(mine.count) >= 0.6 : shared == mine.count
                if isEcho { return false }
            }
            return true
        }
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    /// 750 s → "12m30"
    public static func stamp(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%02dm%02d", s / 60, s % 60)
    }

    /// 750 s → "12:30", 3725 s → "1:02:05"
    public static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func dateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    /// Folder name for a meeting: "2026-10-19_1502".
    public static func folderName(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return f.string(from: d)
    }
}
