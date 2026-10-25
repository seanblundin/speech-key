import CryptoKit
import Foundation

/// Checks the speech-model files against the fingerprints Speech Key was tested with
/// (`ModelManifest`) before they're used. FluidAudio already checks each download against
/// HuggingFace's own listing, which catches corruption; this also catches a model that was changed
/// on HuggingFace itself. That matters for a dictation app: a tampered model could make Speech Key
/// "hear" whatever an attacker wanted and paste it (Sean, 2026-10-25).
public enum ModelIntegrity {
    public struct Mismatch: LocalizedError {
        public let file: String
        public var errorDescription: String? {
            "The speech model file “\(file)” isn't the one Speech Key was tested with, so it won't be used. Update Speech Key, or delete ~/Library/Application Support/FluidAudio/Models to download the models again."
        }
    }

    /// Files that passed, by path, with the size and date they had then; unchanged files aren't
    /// hashed again on every launch.
    private static let cacheKey = "modelIntegrityChecked"

    /// Throws if any file in `folder` (one of FluidAudio's model folders) is unknown or changed.
    /// Folders the manifest doesn't cover (models only the benchmark uses) are let through.
    public static func verify(_ folder: URL) throws {
        let name = folder.lastPathComponent
        let expected = ModelManifest.files.filter { $0.key.hasPrefix(name + "/") }
        guard !expected.isEmpty else { return }
        let fm = FileManager.default
        var checked = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { throw Mismatch(file: name) }
        var seen = 0
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let rel = name + "/" + url.path.dropFirst(folder.path.count + 1)
            guard let want = expected[rel] else { throw Mismatch(file: rel) }
            seen += 1
            let stamp = "\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            if checked[rel] == stamp { continue }
            guard try sha256(url) == want else {
                checked[rel] = nil
                UserDefaults.standard.set(checked, forKey: cacheKey)
                throw Mismatch(file: rel)
            }
            checked[rel] = stamp
        }
        UserDefaults.standard.set(checked, forKey: cacheKey)
        // FluidAudio downloads all of a model's files; a folder missing some is incomplete.
        if seen < expected.count { throw Mismatch(file: name + " (incomplete)") }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
