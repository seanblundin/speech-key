import Foundation
import SpeechEngine

/// Telling the voices in a mic-only meeting apart (Sean, 2026-11-26: "if I'm rolling a meeting in
/// person and there's 3 people in person and zero computer audio"). The mic is recorded to a file
/// while the meeting runs; at each snapshot and at the end the whole recording is split by voice
/// (`SpeakerSplitter`), and each transcript line gets the name of the voice that overlaps it most:
/// "Me" for the voice that matches the user's dictations, "Speaker 1", "Speaker 2"… for the rest.
enum MeetingVoices {
    /// Shorter recordings are left as "Room": too little speech to tell voices apart.
    static let minimumSeconds: TimeInterval = 20

    struct Result {
        /// Mic line start time → name.
        var names: [TimeInterval: String] = [:]
        /// Name → that voice's fingerprint, to keep names steady at the next snapshot.
        var prints: [String: [Float]] = [:]
        var seconds: TimeInterval = 0
    }

    /// Names for the mic lines of `transcript`, from the recording at `tape`.
    static func name(_ transcript: MeetingTranscript, tape: URL, previous: [String: [Float]]) async throws -> Result {
        let started = Date()
        let split = try await SpeakerSplitter.shared.split(file: tape)
        let mine = await VoicePrint.mine()
        let micLines = transcript.lines.filter { $0.speaker == MeetingTranscript.me }
        let voices = VoiceLabels.assign(lines: micLines.map { ($0.start, $0.end) },
                                        turns: split.turns.map { ($0.voice, $0.start, $0.end) })
        var order: [String] = []
        for case let v? in voices where !order.contains(v) { order.append(v) }
        let names = VoiceLabels.names(order: order, prints: split.prints, mine: mine, previous: previous)
        var out = Result()
        for (line, voice) in zip(micLines, voices) {
            if let voice, let name = names[voice] { out.names[line.start] = name }
        }
        for (voice, name) in names { if let p = split.prints[voice] { out.prints[name] = p } }
        out.seconds = Date().timeIntervalSince(started)
        return out
    }

    /// Keeps the mic recordings of the three newest meetings when recordings are being kept
    /// (`keepAudio`), for checking how well voices are told apart; otherwise removes any left behind.
    static func pruneTapes(in root: URL, except live: URL? = nil) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let tapes = folders.map { $0.appendingPathComponent(MicTape.name) }
            .filter { fm.fileExists(atPath: $0.path) && $0.deletingLastPathComponent().path != live?.path }
            .sorted { $0.path > $1.path }       // folder names start with the date, so newest first
        let keep = AudioKeep.limit > 0 ? 3 : 0
        for tape in tapes.dropFirst(keep) { try? fm.removeItem(at: tape) }
    }
}

/// The mic's side of a meeting as a 16 kHz mono WAV, written as the meeting runs. Its clock is the
/// meeting's clock (gaps are padded with silence before they get here), so voice turns found in it
/// line up with transcript lines. About 115 MB an hour; removed when the meeting ends unless
/// recordings are being kept.
final class MicTape: @unchecked Sendable {
    static let name = ".mic.wav"
    let url: URL
    private let queue = DispatchQueue(label: "speechkey.mictape")
    private var handle: FileHandle?
    private var frames = 0

    init?(folder: URL) {
        url = folder.appendingPathComponent(Self.name)
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(frames: 0)),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? h.seekToEnd()
        handle = h
    }

    func append(_ samples: [Float]) {
        queue.async { [self] in
            guard let handle else { return }
            var data = Data(count: samples.count * 2)
            data.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: Int16.self)
                for i in samples.indices { out[i] = Int16(max(-1, min(1, samples[i])) * 32767).littleEndian }
            }
            do { try handle.write(contentsOf: data); frames += samples.count } catch { self.handle = nil }
        }
    }

    /// Makes the file a complete WAV of everything so far, and says how many seconds that is.
    func seal() -> TimeInterval {
        queue.sync {
            guard let handle else { return 0 }
            try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: Self.header(frames: frames))
            _ = try? handle.seekToEnd()
            try? handle.synchronize()
            return Double(frames) / 16_000
        }
    }

    func close(keep: Bool) {
        _ = seal()
        queue.sync {
            try? handle?.close()
            handle = nil
            if !keep { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func header(frames: Int) -> Data {
        let bytes = UInt32(frames * 2)
        var d = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1); put32(16_000); put32(32_000); put16(2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(bytes)
        return d
    }
}

/// The user's own voice as 256 numbers, so a mic-only meeting can say which voice is "Me". Made
/// from kept dictation recordings (the `keepAudio` setting), since every dictation is the user
/// talking; without kept recordings there is no fingerprint and every voice gets a number.
/// Stored in `voiceprint.json` next to the logs, remade weekly. Never leaves the Mac.
enum VoicePrint {
    struct Saved: Codable { let print: [Float]; let made: Date; let seconds: Double }
    static let file = DictationLog.directory.appendingPathComponent("voiceprint.json")
    private static let maxAge: TimeInterval = 7 * 86_400

    static func mine() async -> [Float]? {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        if let saved, Date().timeIntervalSince(saved.made) < maxAge { return saved.print }
        return await remake() ?? saved?.print
    }

    /// About five minutes of the newest kept dictations, split by voice; the voice that did most of
    /// the talking is the user.
    static func remake() async -> [Float]? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: AudioKeep.folder, includingPropertiesForKeys: nil) else { return nil }
        var samples: [Float] = []
        let gap = [Float](repeating: 0, count: 8_000)
        for f in files.filter({ $0.pathExtension == "m4a" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard samples.count < 300 * 16_000, let clip = try? SpeechEngine.loadAudioFile(f) else { continue }
            // Skip scraps, and recordings left running by accident.
            guard clip.count >= 4 * 16_000, clip.count <= 300 * 16_000 else { continue }
            samples += clip + gap
        }
        guard samples.count >= 60 * 16_000, let split = try? await SpeakerSplitter.shared.split(samples: samples) else { return nil }
        let seconds = split.seconds
        guard let main = seconds.max(by: { $0.value < $1.value }), let print = split.prints[main.key],
              main.value >= 0.6 * seconds.values.reduce(0, +) else { return nil }
        if let data = try? JSONEncoder().encode(Saved(print: print, made: Date(), seconds: main.value)) {
            try? data.write(to: file, options: .atomic)
        }
        UtterLog.write(String(format: "voiceprint made from %.0fs of dictations", main.value))
        return print
    }
}
