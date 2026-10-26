import AppKit
import SpeechEngine

/// Meeting mode's controls: ⌃⌥ fn starts and ends a meeting, ⌃ fn saves a snapshot.
/// Every press gets a short popup, because the hotkey is otherwise invisible. No sounds: Sean
/// wants silence from every keyboard action (2026-10-20).
@MainActor
final class MeetingController {
    /// `Documents/Speech Key Meetings` unless changed in settings.
    static var root: URL { UtterPaths.meetings }
    /// After this long with no speech on either stream, the meeting saves and stops itself.
    static let silenceLimit: TimeInterval = 600

    private let pill: PillController
    private let engine: () async -> SpeechEngine?
    private let glossary: () -> Glossary
    private var session: MeetingSession?
    private var ticker: Timer?
    private var busy = false
    private var warnedAboutCallAudio = false
    /// Called every second while a meeting runs, and on start/stop, so the menu bar can update.
    var onChange: (() -> Void)?
    /// Meetings starting and ending, and snapshots, for History.
    var onEvent: ((AppEvent) -> Void)?
    /// Writes each meeting's title: at every snapshot, and again at its end.
    var titler: MeetingTitler?
    private var snapshotsTaken = 0
    var rootOverride: URL?

    init(pill: PillController, engine: @escaping () async -> SpeechEngine?, glossary: @escaping () -> Glossary) {
        self.pill = pill
        self.engine = engine
        self.glossary = glossary
    }

    var isRunning: Bool { session != nil }
    var elapsed: TimeInterval { session?.elapsed ?? 0 }
    var startedAt: Date? { session?.startedAt }
    var root: URL { rootOverride ?? Self.root }
    var folder: URL? { session?.folder }

    func toggle() {
        if isRunning { end() } else { start() }
    }

    func start() {
        guard session == nil, !busy else { return }
        guard Permissions.mic == .granted else {
            pill.show(.message("I need the mic to record meetings"), autoHideAfter: 2.5)
            if Permissions.mic == .notAsked { Permissions.requestMic { _ in } } else { Permissions.openMicrophoneSettings() }
            return
        }
        busy = true
        let s = MeetingSession(root: rootOverride ?? Self.root, engine: engine, glossary: glossary)
        session = s
        snapshotsTaken = 0
        warnedAboutCallAudio = false
        Task {
            do {
                try await s.start()
                // Doubles as the reminder that everyone should know they're being recorded.
                pill.show(.message("Recording · let everyone know"), autoHideAfter: 2.5)
            } catch {
                // The mic works but call audio doesn't: keep going with the mic alone.
                if Permissions.mic == .granted, error is SystemAudioTap.TapError {
                    pill.show(.message("Recording you only. I can't hear the call"), autoHideAfter: 3.5)
                } else {
                    s.stopCapture()
                    session = nil
                    pill.show(.message("Couldn't start the meeting: \(error.localizedDescription)"), autoHideAfter: 3.5)
                }
            }
            busy = false
            if session === s { onEvent?(AppEvent(time: s.startedAt, kind: .meetingStarted, folder: s.folder.path)) }
            startTicker()
            onChange?()
        }
    }

    func snapshot() {
        guard let s = session, !busy else {
            if session == nil { pill.show(.message("No meeting on · ⌃⌥ 🌐 starts one"), autoHideAfter: 2) }
            return
        }
        busy = true
        pill.show(.message("Saving…"))
        Task {
            let part = await s.snapshot()
            copyPath(part.file)
            pill.show(.done("Snapshot \(part.number) saved · path copied"), autoHideAfter: 2.2)
            snapshotsTaken += 1
            let n = snapshotsTaken
            MeetingMeta.update(s.folder) { $0.snapshots = n }
            onEvent?(AppEvent(time: Date(), kind: .snapshot, folder: s.folder.path, file: part.file.path, part: part.number, seconds: part.end))
            titler?.title(s.folder, force: true)
            busy = false
        }
    }

    func end(reason: String? = nil) {
        guard let s = session, !busy else { return }
        busy = true
        ticker?.invalidate()
        pill.show(.message("Wrapping up…"))
        Task {
            let result = await s.finish()
            session = nil
            busy = false
            let n = MeetingTranscript.snapshotCount(parts: result.parts)
            MeetingMeta.update(s.folder) { $0.snapshots = n }
            onEvent?(AppEvent(time: Date(), kind: .meetingEnded, folder: s.folder.path, seconds: result.length, snapshots: n))
            titler?.title(s.folder, force: true)
            let summary = (["That's a wrap"] + (n > 0 ? ["\(n) snapshots"] : []) + [MeetingTranscript.clock(result.length)])
                .joined(separator: " · ")
            pill.show(.done(reason ?? summary), autoHideAfter: 3)
            copyPath(s.folder.appendingPathComponent(MeetingNames.full(s.folder.lastPathComponent)))
            onChange?()
        }
    }

    func openFolder() {
        let url = session?.folder ?? (rootOverride ?? Self.root)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let s = session else { ticker?.invalidate(); return }
        onChange?()
        if !warnedAboutCallAudio, s.elapsed > 90, !s.heardCallAudio {
            warnedAboutCallAudio = true
            pill.show(.message("I still can't hear the call. Check System Audio access"), autoHideAfter: 5)
        }
        if Date().timeIntervalSince(s.lastSpeechAt) > Self.silenceLimit, !busy {
            end(reason: "It went quiet, so I saved and stopped")
        }
    }

    private func copyPath(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
    }
}
