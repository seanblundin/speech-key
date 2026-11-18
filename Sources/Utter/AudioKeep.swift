import AVFoundation
import Foundation

/// Keeps the sound of the most recent dictations on this Mac, so a new speech model can be scored
/// on real speech (`engine-bench --history`). Off unless asked for:
///   defaults write ~/Library/Preferences/com.seanblundin.utter.plist keepAudio -int 200
/// Each recording is a lossless .m4a named after its dictation's time in `dictations.jsonl`.
/// Nothing is ever uploaded.
enum AudioKeep {
    static let key = "keepAudio"
    static let folder = DictationLog.directory.appendingPathComponent("audio", isDirectory: true)
    /// Whatever the count, the folder never grows past this.
    static let maxBytes = 300_000_000

    /// How many recordings to keep. 0 keeps none.
    static var limit: Int { UserDefaults.standard.integer(forKey: key) }

    /// The file for a dictation logged at `time`.
    static func file(for time: Date) -> URL {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return folder.appendingPathComponent(f.string(from: time).replacingOccurrences(of: ":", with: "-") + ".m4a")
    }

    /// Saves in the background; a dictation never waits for it.
    static func save(_ samples: [Float], time: Date, sampleRate: Double) {
        let limit = limit
        guard limit > 0, !samples.isEmpty else { return }
        let url = file(for: time)
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try write(samples, to: url, sampleRate: sampleRate)
                prune(keeping: limit)
            } catch {
                UtterLog.write("couldn't keep the recording: \(error.localizedDescription)")
            }
        }
    }

    static func write(_ samples: [Float], to url: URL, sampleRate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    /// Deletes the oldest recordings beyond `count`, and beyond `maxBytes` in all.
    static func prune(keeping count: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        // Names are times, so sorting by name is oldest first.
        let sorted = files.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        var bytes = 0
        for (i, f) in sorted.enumerated() {
            bytes += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if i >= count || bytes > maxBytes { try? fm.removeItem(at: f) }
        }
    }
}
