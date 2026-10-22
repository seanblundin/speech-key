import AppKit
import SpeechEngine

/// Where Utter keeps the two files people care about: the glossary and the meeting transcripts.
///
/// By default, an app-owned glossary and a folder in Documents. Either can be changed in settings,
/// for example to share a glossary file with other tools.
enum UtterPaths {
    private static let glossaryKey = "glossaryPath"
    private static let meetingsKey = "meetingsFolder"

    static var glossary: String {
        if let chosen = UserDefaults.standard.string(forKey: glossaryKey), FileManager.default.fileExists(atPath: chosen) {
            return chosen
        }
        return ownGlossary()
    }

    static var meetings: URL {
        if let chosen = UserDefaults.standard.string(forKey: meetingsKey) { return URL(fileURLWithPath: chosen, isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Speech Key Meetings", isDirectory: true)
    }

    static func setGlossary(_ path: String) { UserDefaults.standard.set(path, forKey: glossaryKey) }
    static func setMeetings(_ url: URL) { UserDefaults.standard.set(url.path, forKey: meetingsKey) }

    /// `~/Library/Application Support/Utter/glossary.md`, created with an empty table on first use.
    private static func ownGlossary() -> String {
        let url = DictationLog.directory.appendingPathComponent("glossary.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: DictationLog.directory, withIntermediateDirectories: true)
            try? starter.write(to: url, atomically: true, encoding: .utf8)
        }
        return url.path
    }

    private static var starter: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return """
        *Last edited: \(f.string(from: Date()))*

        Goal: names and words Speech Key gets wrong, with the right spelling. Speech Key fixes them on its own from your next dictation.

        Edit it in the Glossary tab of Speech Key's menu-bar panel, fix a word in History, or hold ⇧ and the globe key and say "Jammy should be Jimmy".

        \(GlossaryDocument.formatLine)

        \(GlossaryDocument.header)
        \(GlossaryDocument.separator)
        """
    }
}
