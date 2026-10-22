import AppKit
import Hotkeys
import SpeechEngine

/// What happens to a finished dictation. Sean can turn off pasting in the panel's settings (2026-10-20).
enum AfterDictation: String, CaseIterable {
    /// Paste into the focused app (the clipboard is restored afterwards).
    case paste
    /// Put it on the clipboard only.
    case copy
    /// Touch neither; it's in the panel's history to copy later.
    case save

    static let key = "afterDictation"
    static var current: AfterDictation {
        AfterDictation(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .paste
    }
}

/// Runs one recording at a time: record while fn is held, transcribe, then either fix names,
/// tidy and paste (dictation), or hand the words to `onCommand` (talking to Utter).
@MainActor
final class DictationController: FnKeyMonitorDelegate {
    enum EngineState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var engineState: EngineState = .loading { didSet { onChange?() } }
    /// Called whenever something the menu or setup window shows has changed.
    var onChange: (() -> Void)?
    /// Every finished dictation, for the panel's history.
    var onDictation: ((DictationLog.Entry) -> Void)?
    /// What Sean said to Utter (⇧ fn), cleaned of fillers but not glossary-fixed.
    var onCommand: ((_ text: String, _ raw: String) -> Void)?

    let pill = PillController()
    let paster = Paster()
    private let recorder = AudioRecorder()
    var log = DictationLog()
    private var engine: SpeechEngine?
    private var engineWaiters: [CheckedContinuation<SpeechEngine?, Never>] = []

    private var glossary: Glossary = .empty
    private var glossaryModified: Date?
    private var glossaryPath: String?
    private(set) var lastRaw: String?
    private(set) var lastFinal: String?

    /// Long dictations are cut at pauses and transcribed while Sean is still talking,
    /// so releasing fn only leaves the last few seconds to process.
    private static let chunking: PauseChunker.Config = {
        var c = PauseChunker.Config()
        c.minChunk = 10
        c.maxChunk = 25      // FluidAudio windows longer chunks itself; forced cuts are the riskiest
        c.minPause = 0.5
        return c
    }()

    private final class Session {
        let kind: FnChordMachine.Recording
        var handsFree: Bool
        let app: String?
        var chunker: PauseChunker?
        var feed: AsyncStream<[Float]>.Continuation?
        var feedTask: Task<Void, Never>?
        var parts: [Task<String, Never>] = []
        var cancelled = false
        /// Speech evidence, so a recording with nothing said ends quietly instead of "Didn't catch that".
        var loudBuffers = 0
        var vadHeardSpeech = false
        let began = Date()
        var heardSpeech: Bool { vadHeardSpeech || loudBuffers >= 4 }
        init(kind: FnChordMachine.Recording, handsFree: Bool, app: String?) {
            self.kind = kind; self.handsFree = handsFree; self.app = app
        }
    }

    private var session: Session?
    private var working = false
    /// Tests: transcribe and report, but never paste or copy (`--simulate-keys`).
    var dryRun = false
    /// Decides glossary rows that need judgment, with Apple's on-device model.
    var judge: GlossaryJudge?

    // MARK: - Engine

    func loadEngine() {
        recorder.prewarm()
        reloadGlossaryIfChanged()
        Task {
            do {
                let e = try await SpeechEngine(model: .ultra, boostNames: true)
                engine = e
                engineState = .ready
                UtterLog.write("engine ready")
                _ = try? await PauseChunker.make()   // load VAD now rather than on the first long dictation
            } catch {
                engineState = .failed(error.localizedDescription)
                UtterLog.write("engine failed: \(error)")
            }
            let waiters = engineWaiters
            engineWaiters.removeAll()
            for w in waiters { w.resume(returning: engine) }
        }
    }

    /// The one engine, shared with meeting mode.
    func sharedEngine() async -> SpeechEngine? { await readyEngine() }

    /// The glossary, reloaded if the file changed.
    func currentGlossary() -> Glossary {
        reloadGlossaryIfChanged()
        return glossary
    }

    private func readyEngine() async -> SpeechEngine? {
        if let engine { return engine }
        if case .failed = engineState { return nil }
        return await withCheckedContinuation { engineWaiters.append($0) }
    }

    private func reloadGlossaryIfChanged() {
        let path = UtterPaths.glossary
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard modified != glossaryModified || path != glossaryPath else { return }
        glossaryModified = modified
        glossaryPath = path
        glossary = (try? Glossary.load(path: path)) ?? .empty
    }

    // MARK: - fn key

    func startRecording(_ kind: FnChordMachine.Recording) { begin(kind) }
    func cancelRecording() { cancel(showMessage: false) }
    func finishRecording() { finish() }
    func escapePressed() { cancel(showMessage: true) }

    func keepRecordingHandsFree() {
        guard let s = session else { return }
        s.handsFree = true
        UtterLog.write("hands-free")
        pill.show(.handsFree)
    }

    // MARK: - Session

    private func begin(_ kind: FnChordMachine.Recording, handsFree: Bool = false) {
        guard session == nil else { return }
        guard Permissions.mic == .granted else {
            pill.show(.message("Speech Key needs microphone access"), autoHideAfter: 2.5)
            if Permissions.mic == .notAsked { Permissions.requestMic { _ in } } else { Permissions.openMicrophoneSettings() }
            return
        }
        reloadGlossaryIfChanged()
        let s = Session(kind: kind, handsFree: handsFree, app: NSWorkspace.shared.frontmostApplication?.localizedName)
        session = s
        pill.model.talkingToUtter = kind == .command

        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        s.feed = continuation
        s.feedTask = Task { [weak self] in await self?.consume(stream, into: s) }
        UtterLog.write("recording started (\(kind == .command ? "agent" : "dictation")\(handsFree ? ", hands-free" : ""))")

        // The mic opens off the main thread; the pill and the key tap don't wait for it.
        recorder.begin(samples: { continuation.yield($0) }, level: { [weak self] level in
            guard let self else { return }
            if level > 0.45 { s.loudBuffers += 1 }
            if self.session === s { self.pill.model.push(level: level) }
        }, opened: { [weak self] error, took in
            if took > 0.3 { UtterLog.write(String(format: "mic took %.2fs to open", took)) }
            if self?.dryRun == true { print(String(format: "mic open took %.3fs", took)); fflush(stdout) }
            guard let self, let error else { return }
            UtterLog.write("mic failed: \(error.localizedDescription)")
            guard self.session === s else { return }
            self.session = nil
            continuation.finish()
            self.pill.show(.message("Couldn't start the microphone"), autoHideAfter: 2.5)
        })

        if handsFree {
            pill.show(.handsFree)
        } else {
            // Don't flash the pill for a quick tap (which might be the first half of a double-tap).
            // A quick second tap turns this same session hands-free before the delay is up; then the
            // hands-free pill (red dot and timer) must stay, not be replaced by the plain one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self, self.session === s, !s.cancelled, !s.handsFree else { return }
                self.pill.show(.listening)
            }
        }
    }

    /// Feeds live audio to the pause chunker and starts transcribing each finished chunk.
    private func consume(_ stream: AsyncStream<[Float]>, into s: Session) async {
        s.chunker = try? await PauseChunker.make(config: Self.chunking)
        for await samples in stream {
            guard let chunker = s.chunker, !s.cancelled else { continue }
            guard let closed = try? await chunker.append(samples) else { continue }
            for chunk in closed {
                if chunk.hasSpeech { s.vadHeardSpeech = true }
                s.parts.append(transcribe(chunk.samples, for: s))
            }
        }
    }

    private func transcribe(_ samples: [Float], for s: Session) -> Task<String, Never> {
        // Commands get no name boosting: "when you hear Teegh, write Tighe" must keep both words.
        let vocabulary = s.kind == .dictation ? glossary.boostTerms : []
        return Task { [weak self] in
            guard let engine = await self?.readyEngine() else { return "" }
            return (try? await engine.text(samples: samples, vocabulary: vocabulary, priority: .interactive)) ?? ""
        }
    }

    private func finish() {
        guard let s = session else { return }
        session = nil
        var all = recorder.end()
        if let samples = simulatedSamples { all = samples; simulatedSamples = nil }
        s.feed?.finish()
        let audioSeconds = Double(all.count) / Double(SpeechEngine.sampleRate)
        UtterLog.write(String(format: "recording finished (%.1fs of audio, %@)", audioSeconds, s.heardSpeech ? "speech" : "quiet"))
        guard audioSeconds >= 0.3 else { pill.hide(); return }
        // Always transcribe: speech evidence is only complete once the tail has been through the VAD.
        // An empty result then ends quietly if nothing was said (see `nothingHeard`).

        working = true
        // Hands-free keeps its own pill while it finishes (dot greyed, timer stopped), so ending it
        // doesn't look like a new recording starting.
        let busy: PillModel.Mode = s.handsFree ? .finishing(Date().timeIntervalSince(pill.model.startedAt)) : .working
        pill.show(engine == nil ? .message("Warming up the speech model…") : busy)
        let started = Date()

        Task { [weak self] in
            guard let self else { return }
            await s.feedTask?.value
            var parts = s.parts
            if let chunker = s.chunker {
                if let tail = chunker.flush(), tail.samples.count >= SpeechEngine.minimumSamples {
                    if tail.hasSpeech { s.vadHeardSpeech = true }
                    parts.append(self.transcribe(tail.samples, for: s))
                }
            } else {
                parts = [self.transcribe(all, for: s)]   // VAD unavailable: do the whole recording at once
            }
            if self.engine == nil { self.pill.show(busy) }
            var texts: [String] = []
            for p in parts { texts.append(await p.value) }
            await self.deliver(raw: ChunkJoiner.join(texts), session: s,
                         audioSeconds: audioSeconds, waitSeconds: Date().timeIntervalSince(started))
        }
    }

    private func deliver(raw: String, session s: Session, audioSeconds: Double, waitSeconds: Double) async {
        working = false
        if case .failed(let reason) = engineState {
            pill.show(.message("Speech model failed to load: \(reason)"), autoHideAfter: 4)
            return
        }
        if s.kind == .command {
            let text = CleanVerbatim.apply(raw)
            guard !text.isEmpty else { nothingHeard(s); return }
            onCommand?(text, raw)
            return
        }
        let fixed = glossary.applyWithChanges(raw)
        var final = CleanVerbatim.apply(fixed.text)
        guard !final.isEmpty else { nothingHeard(s); return }
        // Glossary rows that need judgment ("Eli": Elijah at work, Elias in book club): only when
        // one of their words is here, and never for more than 1.5 s.
        var changes = fixed.changes
        if let judge {
            let candidates = glossary.conditionalCandidates(in: final)
            if !candidates.isEmpty {
                let decisions = await judge.decide(text: final, candidates: candidates)
                if !decisions.isEmpty {
                    let applied = Glossary.applying(decisions, to: final)
                    final = applied.text
                    changes += applied.changes
                }
            }
        }
        // So back-to-back dictations don't run together.
        if let last = final.last, ".!?".contains(last) { final += " " }

        lastRaw = raw
        lastFinal = final
        onChange?()
        print(String(format: "[utter] %.1fs audio, %.2fs after release\n  raw:   %@\n  final: %@", audioSeconds, waitSeconds, raw, final))
        fflush(stdout)
        if s.app == "simulation" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }

        let after = AfterDictation.current
        if s.app == "simulation" || dryRun {
            // Tests don't touch the clipboard.
        } else if after == .copy {
            paster.copy(final.trimmingCharacters(in: .whitespaces))
        } else if after == .save {
            // Only the panel's history gets it; the clipboard and the focused app are left alone.
        } else if Permissions.accessibility {
            // "Pasted" waits until the focused app has actually read the text.
            let entry = DictationLog.Entry(time: Date(), app: s.app, raw: raw, final: final, changes: changes.map(\.description),
                                           audioSeconds: audioSeconds, waitSeconds: waitSeconds)
            let label = Self.doneLabel(verb: "Pasted", fixed: changes.map(\.to), after: after)
            paster.paste(final) { [weak self] result in
                guard let self else { return }
                switch result {
                case .landed:
                    pill.show(.done(label), autoHideAfter: 1.4)
                    record(entry)
                case .missed:
                    UtterLog.write("paste not taken by \(s.app ?? "the focused app"); left on the clipboard")
                    if session == nil { pill.show(.message("Copied · press ⌘V to paste"), autoHideAfter: 3) }
                    var copied = entry
                    copied.delivery = "copy"
                    record(copied)
                case .cutShort:
                    record(entry)
                }
            }
            return
        } else {
            paster.copy(final)
            pill.show(.message("Copied. Allow Accessibility in Settings to paste"), autoHideAfter: 3.5)
            record(.init(time: Date(), app: s.app, raw: raw, final: final, changes: changes.map(\.description),
                         audioSeconds: audioSeconds, waitSeconds: waitSeconds, delivery: "copy"))
            return
        }

        let verb = after == .copy ? "Copied" : after == .save ? "Saved to the menu bar" : "Pasted"
        pill.show(.done(Self.doneLabel(verb: verb, fixed: changes.map(\.to), after: after)), autoHideAfter: 1.4)

        record(.init(time: Date(), app: s.app, raw: raw, final: final, changes: changes.map(\.description),
                     audioSeconds: audioSeconds, waitSeconds: waitSeconds,
                     delivery: after == .copy ? "copy" : after == .save ? "save" : nil))
    }

    /// "Pasted", "Copied · fixed NOVA", or "Fixed NOVA, Tighe" (a paste that fixed names).
    private static func doneLabel(verb: String, fixed: [String], after: AfterDictation) -> String {
        let names = NSOrderedSet(array: fixed).array as! [String]
        if names.isEmpty { return verb }
        if after != .paste { return verb + " · fixed " + names.prefix(2).joined(separator: ", ") }
        return "Fixed " + names.prefix(3).joined(separator: ", ")
    }

    /// An empty transcript: say so only if there was speech to catch.
    private func nothingHeard(_ s: Session) {
        if s.heardSpeech || s.app == "simulation" {
            pill.show(.message("Didn't catch that"), autoHideAfter: 1.6)
        } else {
            pill.hide()
        }
    }

    private func record(_ entry: DictationLog.Entry) {
        log.append(entry)
        onDictation?(entry)
    }

    private func cancel(showMessage: Bool) {
        guard let s = session else { return }
        s.cancelled = true
        session = nil
        recorder.end()
        UtterLog.write(showMessage ? "recording cancelled (Esc)" : "recording dropped (a tap or another chord)")
        s.feed?.finish()
        s.parts.forEach { $0.cancel() }
        if showMessage { pill.show(.message("Cancelled"), autoHideAfter: 0.9) } else { pill.hide() }
    }

    // MARK: - Testing

    /// Runs an audio file through the real pipeline (chunking, engine, glossary, cleanup, paste),
    /// fed at real-time speed as if it came from the mic: `Utter --simulate file.wav`.
    func simulate(file: URL, kind: FnChordMachine.Recording = .dictation, handsFree: Bool = true) {
        Task {
            guard let samples = try? SpeechEngine.loadAudioFile(file) else { NSLog("Speech Key: can't read \(file.path)"); return }
            _ = await readyEngine()
            let s = Session(kind: kind, handsFree: handsFree, app: "simulation")
            pill.model.talkingToUtter = kind == .command
            session = s
            let (stream, continuation) = AsyncStream<[Float]>.makeStream()
            s.feed = continuation
            s.feedTask = Task { await self.consume(stream, into: s) }   // test-only path; the app lives for the whole run
            pill.show(handsFree ? .handsFree : .listening)
            let step = SpeechEngine.sampleRate / 10
            var i = 0
            while i < samples.count {
                let chunk = Array(samples[i..<min(i + step, samples.count)])
                continuation.yield(chunk)
                var sum: Float = 0
                for v in chunk { sum += v * v }
                pill.model.push(level: min(1, (sum / Float(chunk.count)).squareRoot() * 8))
                i += step
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            simulatedSamples = samples
            finish()
        }
    }
    private var simulatedSamples: [Float]?

    // MARK: - Menu actions

    func copyLast() {
        guard let lastFinal else { return }
        paster.copy(lastFinal.trimmingCharacters(in: .whitespaces))
    }

    func copyLastRaw() {
        guard let lastRaw else { return }
        paster.copy(lastRaw)
    }
}
