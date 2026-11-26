import Foundation
import SpeechEngine

/// Telling the voices in a meeting apart, whatever kind it is (Sean, 2026-11-26: "many voices via
/// computer audio, many via in person… sometimes I'm on a phone call and want a notetaker").
///
/// The transcript is written for a frontier model to read, and one of those can follow a raw
/// transcript well; what it can't do is hear. So the one thing added is who is speaking. Both
/// streams (the mic, and the computer's audio) are recorded to a file while the meeting runs. At
/// each snapshot and at the end, each recording is split by voice (`SpeakerSplitter`), every line
/// gets the voice that overlaps it most, and `VoiceLabels.names` names them all one way: "Me",
/// "Them" when the call is a single voice, otherwise "Speaker 1", "Speaker 2"… in the order
/// people first spoke. Putting real names on the numbers is left to whoever reads the file.
enum MeetingVoices {
    /// Off unless turned on, while it is still being proven on real meetings (as of 0.2.4 it had
    /// never named a live meeting; it is on for Sean's Mac):
    ///   defaults write ~/Library/Preferences/com.seanblundin.utter.plist nameVoices -bool true
    /// Off, a meeting is recorded and saved exactly as before: no stream recordings, no splitting,
    /// and no voices chip in the Meetings tab. Never on macOS 14, where the splitter's models can
    /// crash inside Core ML (an Apple bug fixed in macOS 15; see FluidAudio's diarization notes).
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "nameVoices") && ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }

    /// Shorter recordings are left alone: too little speech to tell voices apart.
    static let minimumSeconds: TimeInterval = 20

    struct Result {
        var names: [MeetingTranscript.LineKey: String] = [:]
        /// Name → that voice's fingerprint, to keep numbers steady at the next snapshot.
        var prints: [String: [Float]] = [:]
        /// The streams that were split and named ("Me", "Them").
        var streams: Set<String> = []
        /// Streams left with their plain label because the splitter couldn't hear them well enough:
        /// the share of words in lines where no voice was found.
        var unheard: [String: Double] = [:]
        var seconds: TimeInterval = 0
    }

    /// Names for the lines of `transcript`, from the recording of each stream (`tapes`: "Me" → the
    /// mic's file, "Them" → the computer audio's).
    static func name(_ transcript: MeetingTranscript, tapes: [String: URL], previous: [String: [Float]]) async throws -> Result {
        let started = Date()
        var out = Result()
        // Each line's voice, as "<stream>/<voice>", and each voice's fingerprint.
        var voiceOf: [MeetingTranscript.LineKey: String] = [:]
        var prints: [String: [Float]] = [:]
        // Echoes of the call picked up by the mic never reach the page, so they don't get named.
        let heard = transcript.heardLines
        for (stream, tape) in tapes.sorted(by: { $0.key < $1.key }) {
            let lines = heard.filter { $0.speaker == stream }
            guard !lines.isEmpty else { continue }
            let split = try await SpeakerSplitter.shared.split(file: tape)
            let voices = VoiceLabels.assign(lines: lines.map { ($0.start, $0.end) }, turns: split.turns.map { ($0.voice, $0.start, $0.end) })
            // Believe the split only if it accounts for nearly everything that was said.
            let words = lines.map { $0.text.split(separator: " ").count }
            let missed = zip(words, voices).filter { $0.1 == nil }.reduce(0) { $0 + $1.0 }
            let share = Double(missed) / Double(max(1, words.reduce(0, +)))
            guard share <= VoiceLabels.unheardLimit else {
                out.unheard[stream] = share
                // The room's voices can't be told apart, but the user's own lines often still can:
                // fingerprint each line by itself and compare it with the user's voice.
                if stream == MeetingTranscript.me, transcript.micOnly, let mine = await VoicePrint.mineByLine() {
                    var scored: [(start: TimeInterval, end: TimeInterval, score: Float)] = []
                    for line in lines {
                        // At least 1.2 s of sound, centred on the line.
                        let pad = max(0, (1.2 - (line.end - line.start)) / 2)
                        let sound = StreamTape.samples(of: tape, from: line.start - pad, to: line.end + pad)
                        let print = sound.count >= 8_000 ? try? await SpeakerSplitter.shared.fingerprint(sound) : nil
                        scored.append((line.start, line.end, print.map { VoiceLabels.similarity($0, mine) } ?? 0))
                    }
                    let isMine = VoiceLabels.mineByLine(scored)
                    if isMine.contains(true) {
                        for (line, mine) in zip(lines, isMine) where mine { out.names[.init(speaker: stream, start: line.start)] = VoiceLabels.me }
                        out.streams.insert(stream)
                    }
                }
                continue
            }
            out.streams.insert(stream)
            for (line, voice) in zip(lines, voices) {
                guard let voice else { continue }
                voiceOf[.init(speaker: stream, start: line.start)] = stream + "/" + voice
            }
            for (voice, print) in split.prints { prints[stream + "/" + voice] = print }
        }
        // In the order they first spoke, across both streams.
        var order: [String] = []
        for line in heard {
            if let id = voiceOf[.init(speaker: line.speaker, start: line.start)], !order.contains(id) { order.append(id) }
        }
        let voices = order.map { VoiceLabels.Voice(id: $0, print: prints[$0], onMic: $0.hasPrefix(MeetingTranscript.me + "/")) }
        let mine = voices.contains(where: \.onMic) ? await VoicePrint.mine() : nil
        let names = VoiceLabels.names(voices: voices, mine: mine, previous: previous)
        for (key, id) in voiceOf { out.names[key] = names[id] }
        for (id, name) in names { if let p = prints[id] { out.prints[name] = p } }
        out.seconds = Date().timeIntervalSince(started)
        return out
    }

    /// Keeps the recordings of the three newest meetings when recordings are being kept
    /// (`keepAudio`), for checking how well voices are told apart; otherwise removes any left behind.
    static func pruneTapes(in root: URL) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        // Folder names start with the date, so newest first.
        let withTapes = folders.filter { f in StreamTape.names.contains { fm.fileExists(atPath: f.appendingPathComponent($0).path) } }
            .sorted { $0.path > $1.path }
        let keep = AudioKeep.limit > 0 ? 3 : 0
        for folder in withTapes.dropFirst(keep) {
            for name in StreamTape.names { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
        }
    }
}

/// One stream of a meeting (the mic, or the computer's audio) as a 16 kHz mono WAV, written as
/// the meeting runs. Its clock is the meeting's clock (gaps are padded with silence before they
/// get here), so voice turns found in it line up with transcript lines. About 115 MB an hour;
/// removed when the meeting ends unless recordings are being kept.
final class StreamTape: @unchecked Sendable {
    static let mic = ".mic.wav", call = ".call.wav"
    static let names = [mic, call]
    let url: URL
    private let queue = DispatchQueue(label: "speechkey.mictape")
    private var handle: FileHandle?
    private var frames = 0

    init?(folder: URL, name: String) {
        url = folder.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(frames: 0)),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? h.seekToEnd()
        handle = h
    }

    /// A stretch of a tape (seconds from its start) as samples, read straight from the file.
    static func samples(of url: URL, from: TimeInterval, to: TimeInterval) -> [Float] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let first = max(0, Int(from * 16_000)), last = max(first, Int(to * 16_000))
        guard (try? handle.seek(toOffset: UInt64(44 + first * 2))) != nil,
              let data = try? handle.read(upToCount: (last - first) * 2) else { return [] }
        return data.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
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

/// The user's own voice as 256 numbers, so a meeting can say which voice on the mic is "Me". Made
/// from kept dictation recordings (the `keepAudio` setting), since every dictation is the user
/// talking; without kept recordings there is no fingerprint and every voice gets a number.
/// Stored in `voiceprint.json` next to the logs, remade weekly. Never leaves the Mac.
enum VoicePrint {
    struct Saved: Codable {
        let print: [Float]; let made: Date; let seconds: Double
        /// The same voice from the fingerprinter used on single lines (`SpeakerSplitter.fingerprint`);
        /// its numbers aren't comparable with `print`.
        var line: [Float]? = nil
    }
    static let file = DictationLog.directory.appendingPathComponent("voiceprint.json")
    private static let maxAge: TimeInterval = 7 * 86_400

    static func mine() async -> [Float]? {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        if let saved, Date().timeIntervalSince(saved.made) < maxAge { return saved.print }
        return await remake() ?? saved?.print
    }

    /// The user's voice for comparing single lines against: the newest kept dictations, each
    /// fingerprinted by itself, averaged. Saved next to the main fingerprint.
    static func mineByLine() async -> [Float]? {
        var saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        if let line = saved?.line, let made = saved?.made, Date().timeIntervalSince(made) < maxAge { return line }
        guard let files = try? FileManager.default.contentsOfDirectory(at: AudioKeep.folder, includingPropertiesForKeys: nil) else { return saved?.line }
        var sum = [Float](repeating: 0, count: 256)
        var used = 0
        for f in files.filter({ $0.pathExtension == "m4a" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) where used < 16 {
            guard let clip = try? SpeechEngine.loadAudioFile(f), clip.count >= 4 * 16_000, clip.count <= 300 * 16_000,
                  let p = try? await SpeakerSplitter.shared.fingerprint(Array(clip.dropFirst(8_000))), p.count == sum.count else { continue }
            for i in sum.indices { sum[i] += p[i] }
            used += 1
        }
        guard used >= 3 else { return saved?.line }
        let line = VoiceLabels.unit(sum)
        // Kept with the main fingerprint when there is one; this alone never stands in for it.
        if saved != nil {
            saved?.line = line
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
        }
        return line
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
