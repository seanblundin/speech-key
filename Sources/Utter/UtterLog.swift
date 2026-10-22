import Foundation

/// A plain-text diagnostics log at ~/Library/Logs/SpeechKey/speechkey.log (no transcript text, only counts and levels).
enum UtterLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/SpeechKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("speechkey.log")
    }()
    private static let queue = DispatchQueue(label: "speechkey.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// Running audio statistics for one stream, logged every 10 s.
final class StreamStats: @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var samples = 0
    private var sumSquares: Double = 0
    private var peak: Float = 0
    var chunks = 0, speechChunks = 0, transcribed = 0, characters = 0, failures = 0

    init(name: String) { self.name = name }

    func add(_ s: [Float]) {
        var sq: Double = 0
        var p: Float = 0
        for v in s { sq += Double(v * v); p = max(p, abs(v)) }
        lock.lock(); samples += s.count; sumSquares += sq; peak = max(peak, p); lock.unlock()
    }

    func flushLine() -> String {
        lock.lock(); defer { lock.unlock() }
        let rms = samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0
        let db = rms > 0 ? 20 * log10(rms) : -999
        let line = String(format: "%@: %.1fs audio, rms %.1f dBFS, peak %.3f, chunks %d (speech %d), transcribed %d (%d chars), failures %d",
                          name, Double(samples) / 16000, db, peak, chunks, speechChunks, transcribed, characters, failures)
        samples = 0; sumSquares = 0; peak = 0
        return line
    }
}
