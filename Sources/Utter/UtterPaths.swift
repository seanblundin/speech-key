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
        #if APPSTORE
        if let picked = PickedPlaces.url(for: glossaryKey), FileManager.default.fileExists(atPath: picked.path) { return picked.path }
        #else
        if let chosen = UserDefaults.standard.string(forKey: glossaryKey), FileManager.default.fileExists(atPath: chosen) {
            return chosen
        }
        #endif
        return ownGlossary()
    }

    /// In the App Store build the default is inside the app's sandbox folder
    /// (`~/Library/Containers/com.seanblundin.utter/Data/Documents`), since the sandbox only reaches
    /// other folders the user picks.
    static var meetings: URL {
        #if APPSTORE
        if let picked = PickedPlaces.url(for: meetingsKey) { return picked }
        #else
        if let chosen = UserDefaults.standard.string(forKey: meetingsKey) { return URL(fileURLWithPath: chosen, isDirectory: true) }
        #endif
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Speech Key Meetings", isDirectory: true)
    }

    /// Call right after the user picks the file in an open panel, while the sandbox lets the app in.
    static func setGlossary(_ path: String) {
        UserDefaults.standard.set(path, forKey: glossaryKey)
        #if APPSTORE
        PickedPlaces.remember(URL(fileURLWithPath: path), as: glossaryKey)
        #endif
    }

    static func setMeetings(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: meetingsKey)
        #if APPSTORE
        PickedPlaces.remember(url, as: meetingsKey)
        #endif
    }

    /// A picked glossary file is reachable, but its folder isn't, so the App Store build can't
    /// write it through a temporary file next to it.
    static var glossaryWritesAtomically: Bool {
        #if APPSTORE
        PickedPlaces.url(for: glossaryKey) == nil
        #else
        true
        #endif
    }

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

#if APPSTORE
/// Files and folders the user picked, kept across launches as security-scoped bookmarks: the
/// sandbox forgets plain paths when the app quits.
enum PickedPlaces {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var opened: [String: URL] = [:]

    static func remember(_ url: URL, as key: String) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            UtterLog.write("couldn't remember access to \(key)")
            return
        }
        UserDefaults.standard.set(data, forKey: key + "Bookmark")
        lock.lock(); opened[key] = nil; lock.unlock()
    }

    /// The picked place, with access open for the rest of the run; nil if nothing was picked.
    static func url(for key: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let url = opened[key] { return url }
        guard let data = UserDefaults.standard.data(forKey: key + "Bookmark") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: key + "Bookmark")
        }
        opened[key] = url
        return url
    }
}
#endif
