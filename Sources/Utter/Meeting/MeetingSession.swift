import AppKit
import SpeechEngine

/// One meeting: two live streams ("Me" = mic, "Them" = everything the Mac plays), transcribed
/// as they go, kept private until Sean takes a snapshot.
///
/// Files only change on a snapshot (Sean didn't want files changing every few seconds):
/// `<meetings folder>/<date>_<time>_<code>/` with `part-NN_XXmYY-XXmYY_<tag>.md`, `latest_<tag>.md`
/// and `full_<tag>.md`, the tag being the folder's name (see `MeetingNames`).
@MainActor
final class MeetingSession {
    let folder: URL
    let startedAt = Date()
    private(set) var transcript: MeetingTranscript
    private let engine: () async -> SpeechEngine?
    private let vocabulary: () -> [Glossary.Term]
    private let glossary: () -> Glossary

    private let mic = MeetingMic()
    private let tap = SystemAudioTap()
    private var streams: [Stream] = []
    private(set) var lastSpeechAt = Date()
    private var statsTimer: Timer?
    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
    var heardCallAudio: Bool { tap.heardAnything }
    /// Characters transcribed so far from one stream ("Me" or "Them").
    func charactersTranscribed(_ speaker: String) -> Int {
        streams.first { $0.speaker == speaker }?.stats.characters ?? 0
    }

    /// A live stream: audio in, chunks at pauses, each chunk transcribed in order.
    private final class Stream {
        let speaker: String
        let stats: StreamStats
        let feed: AsyncStream<[Float]>.Continuation
        var pump: Task<Void, Never>?
        /// Seconds after the meeting start that this stream's first sample arrived.
        let offset: TimeInterval
        var chunker: PauseChunker?
        var pending: [Task<Void, Never>] = []
        init(speaker: String, feed: AsyncStream<[Float]>.Continuation, offset: TimeInterval) {
            self.speaker = speaker; self.feed = feed; self.offset = offset; self.stats = StreamStats(name: speaker)
        }
    }

    /// Keeps a stream's sample count in step with the wall clock since the meeting started,
    /// padding gaps with silence. Without it, a stream whose audio starts late (the system-audio
    /// permission prompt, a slow device start) has every timestamp shifted, and echoes of the
    /// call no longer line up with the call itself.
    final class StreamClock: @unchecked Sendable {
        private let start: Date
        private var samples = 0
        init(start: Date) { self.start = start }

        func align(_ incoming: [Float]) -> [Float] {
            let now = Date().timeIntervalSince(start)
            let have = Double(samples + incoming.count) / Double(SpeechEngine.sampleRate)
            let gap = now - have
            var out = incoming
            if gap > 0.25 {
                out = [Float](repeating: 0, count: Int(gap * Double(SpeechEngine.sampleRate))) + incoming
            }
            samples += out.count
            return out
        }
    }

    /// Crash safety: every line and snapshot is appended to a hidden `.live.jsonl` the moment it
    /// happens, so a crash loses nothing. A clean finish renames it to `.done.jsonl`; on launch,
    /// `MeetingRecovery` turns any leftover `.live.jsonl` into a final part.
    private lazy var liveLog: FileHandle? = {
        let url = folder.appendingPathComponent(MeetingRecovery.liveName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try? FileHandle(forWritingTo: url)
        // Held for as long as this meeting records, so recovery in another copy of the app can tell
        // the meeting is alive. macOS drops the lock if the app dies, so a real crash still recovers.
        if let h { flock(h.fileDescriptor, LOCK_EX | LOCK_NB) }
        let header = ["started": startedAt.timeIntervalSince1970]
        if let d = try? JSONSerialization.data(withJSONObject: header) { h?.write(d + Data([0x0A])) }
        return h
    }()

    private func log(_ object: [String: Any]) {
        guard let h = liveLog, let d = try? JSONSerialization.data(withJSONObject: object) else { return }
        h.write(d + Data([0x0A]))
    }

    init(root: URL, engine: @escaping () async -> SpeechEngine?, glossary: @escaping () -> Glossary) {
        let code = MeetingNames.newCode()
        let tag = MeetingNames.folder(started: startedAt, code: code)
        self.folder = root.appendingPathComponent(tag, isDirectory: true)
        self.transcript = MeetingTranscript(startedAt: startedAt)
        self.transcript.tag = tag
        self.transcript.code = code
        self.engine = engine
        self.glossary = glossary
        self.vocabulary = { glossary().boostTerms }
    }

    /// Starts both streams. The mic starts first: with AirPods, creating the aggregate device
    /// before the mic is running can leave the mic silent.
    func start() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = liveLog
        UtterLog.write("meeting start: \(folder.lastPathComponent)")
        let me = makeStream(MeetingTranscript.me)
        let meStats = streams.last!.stats
        let meClock = StreamClock(start: startedAt)
        mic.onSamples = { let s = meClock.align($0); meStats.add(s); me.yield(s) }
        do { try mic.start() } catch { UtterLog.write("mic start failed: \(error)"); throw error }
        UtterLog.write("mic started: \(mic.formatDescription)")
        let them = makeStream(MeetingTranscript.them)
        let themStats = streams.last!.stats
        let themClock = StreamClock(start: startedAt)
        tap.onSamples = { let s = themClock.align($0); themStats.add(s); them.yield(s) }
        do { try tap.start() } catch {
            UtterLog.write("system audio tap failed: \(error.localizedDescription)")
            throw error
        }
        UtterLog.write("system audio tap started: \(tap.formatDescription)")
        statsTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.streams.forEach { UtterLog.write($0.stats.flushLine()) } }
        }
    }

    private func makeStream(_ speaker: String) -> AsyncStream<[Float]>.Continuation {
        let (input, feed) = AsyncStream<[Float]>.makeStream()
        // Both streams count samples from the meeting start (see StreamClock), so no offset.
        let stream = Stream(speaker: speaker, feed: feed, offset: 0)
        streams.append(stream)
        // Runs on the main actor; the chunker and engine calls suspend, so this never blocks the UI.
        stream.pump = Task { [weak self] in
            let chunker = try? await PauseChunker.make()
            stream.chunker = chunker
            for await samples in input {
                guard let chunker, let closed = try? await chunker.append(samples) else { continue }
                for chunk in closed {
                    stream.stats.chunks += 1
                    guard chunk.hasSpeech else { continue }
                    stream.stats.speechChunks += 1
                    self?.transcribe(chunk, on: stream, priority: .background)
                }
            }
        }
        return feed
    }

    private func transcribe(_ chunk: PauseChunker.Chunk, on stream: Stream, priority: Priority) {
        let vocab = vocabulary()
        let base = stream.offset + chunk.start
        let speaker = stream.speaker
        let task = Task { [weak self] in
            guard let engine = await self?.engine() else { UtterLog.write("\(speaker): no engine"); stream.stats.failures += 1; return }
            let segments: [Segment]
            do { segments = try await engine.transcribe(samples: chunk.samples, vocabulary: vocab, priority: priority) }
            catch { UtterLog.write("\(speaker): transcribe failed: \(error)"); stream.stats.failures += 1; return }
            stream.stats.transcribed += 1
            stream.stats.characters += segments.reduce(0) { $0 + $1.text.count }
            guard let self else { return }
            let g = self.glossary()
            for s in segments {
                let line = MeetingTranscript.Line(speaker: speaker, start: base + s.start, end: base + s.end, text: g.apply(s.text))
                self.transcript.add(line)
                self.log(["speaker": line.speaker, "start": line.start, "end": line.end, "text": line.text])
            }
            if !segments.isEmpty { self.lastSpeechAt = Date() }
        }
        stream.pending.append(task)
    }

    /// Everything up to this moment, written as the next part. Flushes the open chunk on both
    /// streams first (at interactive priority) so Sean's last sentence makes it in.
    func snapshot() async -> (number: Int, file: URL, end: TimeInterval) {
        let end = elapsed
        for stream in streams {
            // Skip silent tails: the model can invent a word ("nul") out of digital silence.
            if let tail = stream.chunker?.flush(), tail.hasSpeech, tail.samples.count >= SpeechEngine.minimumSamples {
                transcribe(tail, on: stream, priority: .interactive)
            }
        }
        for stream in streams {
            let pending = stream.pending
            stream.pending.removeAll()
            for t in pending { await t.value }
        }
        UtterLog.write("snapshot at \(Int(end))s: \(transcript.lines.count) lines so far")
        let part = transcript.makePart(endingAt: end)
        log(["partEnd": end])
        let file = folder.appendingPathComponent(part.fileName)
        try? part.markdown.write(to: file, atomically: true, encoding: .utf8)
        try? part.markdown.write(to: folder.appendingPathComponent(MeetingNames.latest(folder.lastPathComponent)), atomically: true, encoding: .utf8)
        try? transcript.fullMarkdown(now: end).write(to: folder.appendingPathComponent(MeetingNames.full(folder.lastPathComponent)), atomically: true, encoding: .utf8)
        return (part.number, file, end)
    }

    /// Final snapshot, then stop capturing.
    func finish() async -> (parts: Int, length: TimeInterval) {
        let last = await snapshot()
        stopCapture()
        try? liveLog?.close()
        let fm = FileManager.default
        try? fm.moveItem(at: folder.appendingPathComponent(MeetingRecovery.liveName),
                         to: folder.appendingPathComponent(MeetingRecovery.doneName))
        return (last.number, last.end)
    }

    func stopCapture() {
        statsTimer?.invalidate()
        streams.forEach { UtterLog.write($0.stats.flushLine()) }
        UtterLog.write("meeting stop")
        mic.stop()
        tap.stop()
        for s in streams { s.feed.finish() }
    }
}
