import Foundation

/// Folder and file names for a meeting, so every file says when it was and which meeting it
/// belongs to (Sean, 2026-10-23: "no filename should ever be full.md"):
///
///     2026-10-22_1547_x7bm3z/
///         full_2026-10-22_1547_x7bm3z.md
///         latest_2026-10-22_1547_x7bm3z.md
///         part-02_12m20-27m05_2026-10-22_1547_x7bm3z.md
///
/// The six-character code is new for each meeting, so searching Finder for it finds the folder
/// and every file in it. The folder name (date, time, code) is the `tag` every file ends with.
public enum MeetingNames {
    /// No 0/o or 1/l, so a code read aloud or retyped can't be mistaken.
    static let alphabet = Array("23456789abcdefghjkmnpqrstuvwxyz")

    public static func newCode() -> String {
        String((0..<6).map { _ in alphabet.randomElement()! })
    }

    /// "2026-10-22_1547_x7bm3z".
    public static func folder(started: Date, code: String) -> String {
        MeetingTranscript.folderName(started) + "_" + code
    }

    /// The code at the end of a folder name, or nil for an older folder without one.
    public static func code(ofFolder name: String) -> String? {
        guard let r = name.range(of: #"^\d{4}-\d{2}-\d{2}_\d{4}_([a-z0-9]{6})$"#, options: .regularExpression) else { return nil }
        return String(name[r].suffix(6))
    }

    public static func full(_ tag: String) -> String { "full_\(tag).md" }
    public static func latest(_ tag: String) -> String { "latest_\(tag).md" }

    /// "part-02_12m20-27m05_2026-10-22_1547_x7bm3z.md" (or without the tag, the older form).
    public static func part(_ number: Int, start: TimeInterval, end: TimeInterval, tag: String?) -> String {
        let base = String(format: "part-%02d_%@-%@", number, MeetingTranscript.stamp(start), MeetingTranscript.stamp(end))
        return tag.map { "\(base)_\($0).md" } ?? "\(base).md"
    }

    public static func isPart(_ name: String) -> Bool { name.hasPrefix("part-") && name.hasSuffix(".md") }
    public static func isFull(_ name: String) -> Bool { name == "full.md" || (name.hasPrefix("full_") && name.hasSuffix(".md")) }
    public static func isLatest(_ name: String) -> Bool { name == "latest.md" || (name.hasPrefix("latest_") && name.hasSuffix(".md")) }

    /// Where a part ends, from its name, old or new: "part-04_28m31-51m57…" → 3117.
    public static func partEnd(_ name: String) -> TimeInterval? {
        guard let r = name.range(of: #"^part-\d+_\d+m\d{2}-(\d+)m(\d{2})"#, options: .regularExpression) else { return nil }
        let end = name[r].split(separator: "-").last ?? ""
        let bits = end.split(separator: "m")
        guard bits.count == 2, let m = Double(bits[0]), let s = Double(bits[1]) else { return nil }
        return m * 60 + s
    }

    /// The new name for a file Speech Key wrote under the older scheme, or nil to leave it alone
    /// (files someone else put in the folder, and files already renamed).
    public static func renamed(_ name: String, tag: String) -> String? {
        if name == "full.md" { return full(tag) }
        if name == "latest.md" { return latest(tag) }
        if name.range(of: #"^part-\d+_\d+m\d{2}-\d+m\d{2}\.md$"#, options: .regularExpression) != nil {
            return String(name.dropLast(3)) + "_\(tag).md"
        }
        return nil
    }
}
