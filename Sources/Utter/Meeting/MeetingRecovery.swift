import Foundation
import SpeechEngine

/// Finishes meetings that were cut off by a crash or a forced quit.
///
/// A running meeting keeps a hidden `.live.jsonl` (one line of text per transcribed segment,
/// plus each snapshot's end time). A clean finish renames it to `.done.jsonl`. If Utter starts
/// and finds a `.live.jsonl`, the meeting never finished: write what's left as a final part,
/// refresh `full.md` and `latest.md`, and mark it done.
enum MeetingRecovery {
    static let liveName = ".live.jsonl"
    static let doneName = ".done.jsonl"

    struct Recovered { let folder: URL; let partNumber: Int; let lines: Int }

    static func recoverAll(in root: URL) -> [Recovered] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [Recovered] = []
        for folder in folders where fm.fileExists(atPath: folder.appendingPathComponent(liveName).path) {
            if let r = recover(folder) { out.append(r) }
        }
        return out
    }

    static func recover(_ folder: URL) -> Recovered? {
        let live = folder.appendingPathComponent(liveName)
        guard let text = try? String(contentsOf: live, encoding: .utf8) else { return nil }
        var started = Date()
        var lines: [MeetingTranscript.Line] = []
        var partEnds: [TimeInterval] = []
        for raw in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
            if let t = obj["started"] as? Double { started = Date(timeIntervalSince1970: t) }
            if let e = obj["partEnd"] as? Double { partEnds.append(e) }
            if let speaker = obj["speaker"] as? String, let s = obj["start"] as? Double, let e = obj["end"] as? Double,
               let t = obj["text"] as? String {
                lines.append(.init(speaker: speaker, start: s, end: e, text: t))
            }
        }
        var transcript = MeetingTranscript(startedAt: started, lines: lines, partEnds: partEnds)
        let end = max(transcript.lastLineEnd, partEnds.last ?? 0)
        // Nothing new since the last snapshot: just mark it done.
        let newLines = lines.filter { $0.end > (partEnds.last ?? -1) }
        var partNumber = partEnds.count
        if !newLines.isEmpty {
            let part = transcript.makePart(endingAt: end)
            partNumber = part.number
            let note = "\n_Recovered after Speech Key stopped unexpectedly. Nothing after this point was captured._\n"
            try? (part.markdown + note).write(to: folder.appendingPathComponent(part.fileName), atomically: true, encoding: .utf8)
            try? (part.markdown + note).write(to: folder.appendingPathComponent("latest.md"), atomically: true, encoding: .utf8)
        }
        try? transcript.fullMarkdown(now: end).write(to: folder.appendingPathComponent("full.md"), atomically: true, encoding: .utf8)
        try? FileManager.default.moveItem(at: live, to: folder.appendingPathComponent(doneName))
        MeetingMeta.update(folder) { $0.snapshots = MeetingTranscript.snapshotCount(parts: partNumber) }
        UtterLog.write("recovered \(folder.lastPathComponent): \(lines.count) lines, \(newLines.count) new, part \(partNumber)")
        return Recovered(folder: folder, partNumber: partNumber, lines: newLines.count)
    }
}
