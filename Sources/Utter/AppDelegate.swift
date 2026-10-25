import AppKit
import ServiceManagement
import SpeechEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: DictationController!
    private var fnMonitor: FnKeyMonitor!
    private var setup: SetupWindowController!
    private var meeting: MeetingController!
    private var history: History!
    private var glossaryStore: GlossaryStore!
    private var commands: CommandRunner!
    private var panel: PanelController!
    private var titler: MeetingTitler?
    private var accessibilityPoll: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { launch() }
    }

    @MainActor private func launch() {
        let args = CommandLine.arguments
        // SpeechKey --convert-glossary in.md out.md: the one-table layout, for review.
        if let i = args.firstIndex(of: "--convert-glossary"), i + 2 < args.count,
           let text = try? String(contentsOfFile: args[i + 1], encoding: .utf8) {
            try? GlossaryDocument(markdown: text).markdown.write(toFile: args[i + 2], atomically: true, encoding: .utf8)
            exit(0)
        }
        controller = DictationController()
        func arg(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let testing = args.contains { $0.hasPrefix("--simulate") || $0 == "--render-pill" || $0 == "--test-meeting" || $0 == "--test-paste" || $0 == "--test-titles" || $0 == "--test-update-check" || $0 == "--give-codes" || $0 == "--verify-models" }
        if testing { controller.log.enabled = false }
        fnMonitor = FnKeyMonitor()
        setup = SetupWindowController()
        setup.engineState = { [weak self] in self?.controller.engineState ?? .loading }
        setup.onAllDone = { [weak self] in
            self?.controller.pill.show(.message("Ready. Hold fn and talk"), autoHideAfter: 2.5)
        }
        controller.onChange = { [weak self] in self?.refreshIcon() }
        meeting = MeetingController(pill: controller.pill,
                                    engine: { [weak self] in await self?.controller.sharedEngine() },
                                    glossary: { [weak self] in self?.controller.currentGlossary() ?? .empty })
        meeting.onChange = { [weak self] in self?.refreshIcon() }
        fnMonitor.onSnapshot = { [weak self] in self?.meeting.snapshot() }
        fnMonitor.onToggleMeeting = { [weak self] in self?.meeting.toggle() }

        // Meeting housekeeping, only in the one real copy of the app: test runs and a second copy
        // must never touch a meeting folder (a test once marked a live meeting recovered).
        let alone = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count <= 1
        if !testing && alone {
            let recovered = MeetingRecovery.recoverAll(in: MeetingController.root)
            if let r = recovered.first, r.lines > 0 {
                controller.pill.show(.done("Recovered your last meeting as part \(r.partNumber)"), autoHideAfter: 4)
            }
            EventLog.remap(folders: MeetingLibrary.giveCodesToOlderMeetings(in: MeetingController.root))
        }

        history = History(log: controller.log, events: EventLog(enabled: !testing))
        glossaryStore = GlossaryStore(path: arg("--glossary") ?? UtterPaths.glossary)
        glossaryStore.onChange = { [weak self] in self?.history.record($0) }
        let titler = MeetingTitler()
        self.titler = titler
        meeting.titler = titler
        meeting.onEvent = { [weak self] in self?.history.record($0); self?.panel?.model.refreshMeetings() }
        controller.judge = GlossaryJudge()
        let brain = makeCommandBrain()
        brain.prewarm()
        commands = CommandRunner(brain: brain, glossary: glossaryStore, meeting: meeting, pill: controller.pill,
                                 history: history, log: controller.log)
        controller.onDictation = { [weak self] in self?.history.add($0) }
        controller.onCommand = { [weak self] text, raw in self?.commands.run(text, raw: raw) }
        panel = PanelController(model: makePanelModel(brain: brain))
        panel.model.titler = titler
        titler.onUpdate = { [weak self] in self?.panel?.model.refreshMeetings() }
        panel.willOpen = { [weak self] in self?.refreshPanel() }
        // Remote control, so Claude can take a snapshot or end a meeting on Sean's behalf:
        //   com.seanblundin.utter.meeting.snapshot / .end
        // There is no remote "start": any app can post these, and starting turns on the mic.
        // Off unless turned on (`defaults write com.seanblundin.utter remoteMeetingControl -bool true`,
        // as on Sean's Mac), so other apps can't end or snapshot anyone else's meetings (2026-10-25).
        // Never in the App Store build.
        #if !APPSTORE
        if UserDefaults.standard.bool(forKey: "remoteMeetingControl") {
        let center = DistributedNotificationCenter.default()
        for (name, action) in [("snapshot", { [weak self] in self?.meeting.snapshot() }),
                               ("end", { [weak self] in self?.meeting.end() })] as [(String, () -> Void)] {
            center.addObserver(forName: Notification.Name("com.seanblundin.utter.meeting.\(name)"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            }
        }
        }
        #endif
        UtterLog.write("launch, keys \(Permissions.keys), paste \(Permissions.paste), mic \(Permissions.mic)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "SpeechKey")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Test and design-review modes: no permission prompts.
        if let i = CommandLine.arguments.firstIndex(of: "--render-pill"), i + 1 < CommandLine.arguments.count {
            PillRenderer.renderAll(to: CommandLine.arguments[i + 1])
            PanelRenderer.renderAll(to: CommandLine.arguments[i + 1])
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--demo-pill") { runPillDemo(); return }
        if CommandLine.arguments.contains("--test-paste") { runPasteTest(); return }
        #if !APPSTORE
        if CommandLine.arguments.contains("--test-update-check") { AppUpdates.probe(); return }
        #endif
        if let folder = arg("--verify-models") {
            // SpeechKey --verify-models <model folder>: the integrity check alone, for tests.
            let t0 = Date()
            do { try ModelIntegrity.verify(URL(fileURLWithPath: folder)); print(String(format: "ok, %.2fs", Date().timeIntervalSince(t0))) }
            catch { print("refused: \(error.localizedDescription)") }
            NSApp.terminate(nil)
            return
        }
        if let root = arg("--give-codes") {
            // SpeechKey --give-codes <folder>: the one-time renaming, on a folder you name (a copy).
            for (old, new) in MeetingLibrary.giveCodesToOlderMeetings(in: URL(fileURLWithPath: root)).sorted(by: { $0.key < $1.key }) {
                print("\(URL(fileURLWithPath: old).lastPathComponent) → \(URL(fileURLWithPath: new).lastPathComponent)")
            }
            NSApp.terminate(nil)
            return
        }
        if let root = arg("--test-titles") {
            // SpeechKey --test-titles <meetings folder>: titles every untitled meeting without saving,
            // and prints only whether it worked (never the words, since they're someone's meeting).
            Task { @MainActor in
                for m in MeetingLibrary.list(in: URL(fileURLWithPath: root)) where m.title == nil {
                    guard let text = MeetingLibrary.transcriptText(m.folder) else { print("no transcript  \(m.folder.lastPathComponent)"); continue }
                    let t0 = Date()
                    let r = await MeetingTitler.generate(text)
                    print(String(format: "%@  %@  %.1fs  title %d chars, summary %d chars", r == nil ? "FAILED" : "ok    ",
                                 m.folder.lastPathComponent, Date().timeIntervalSince(t0), r?.title.count ?? 0, r?.summary.count ?? 0))
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--test-meeting"), i + 2 < CommandLine.arguments.count {
            // Utter --test-meeting <dir> <seconds>: start a meeting, snapshot at half time, end at the end.
            meeting.rootOverride = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let seconds = Double(CommandLine.arguments[i + 2]) ?? 30
            controller.loadEngine()
            meeting.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds / 2) { self.meeting.snapshot() }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.meeting.end() }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 8) { NSApp.terminate(nil) }
            return
        }
        if let file = arg("--simulate-command") {
            // Utter --simulate-command clip.wav --glossary /tmp/g.md: talk to Utter from a file.
            controller.loadEngine()
            commands.onFinished = { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) } }
            controller.simulate(file: URL(fileURLWithPath: file), kind: .command)
            return
        }
        if let script = arg("--simulate-keys") {
            runKeyScript(script)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--simulate"), i + 1 < CommandLine.arguments.count {
            controller.loadEngine()
            controller.simulate(file: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }

        fnMonitor.delegate = controller
        controller.loadEngine()
        // Older meetings get titles once, in the background, a minute after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, !self.meeting.isRunning else { return }
            self.titler?.backfill(root: self.meeting.root)
        }

        if Permissions.mic == .notAsked { Permissions.requestMic { _ in } }
        startKeyMonitor()
        AppUpdates.start()

        let firstLaunch = !UserDefaults.standard.bool(forKey: "setupShown")
        if firstLaunch || !Permissions.keys || !Permissions.globeKeyDoesNothing {
            UserDefaults.standard.set(true, forKey: "setupShown")
            setup.show()
        }
    }

    /// Plays scripted fn presses through the real rules, mic, engine and pill, and prints every pill
    /// state with its time. Never pastes. `SpeechKey --simulate-keys "d0 u80 d200 u270 d3000 u3080 end6000"`
    /// (d = fn down, u = fn up, s = say the rest of the token's words aloud, end = quit; times in ms).
    @MainActor private func runKeyScript(_ script: String) {
        controller.dryRun = true
        AudioRecorder.traceTiming = true
        fnMonitor.delegate = controller
        controller.loadEngine()
        Task { @MainActor in
            _ = await self.controller.sharedEngine()
            try? await Task.sleep(nanoseconds: 500_000_000)
            let t0 = Date()
            func stamp() -> String { String(format: "%+7.3fs", Date().timeIntervalSince(t0)) }
            self.controller.pill.onModeChange = { mode in print("\(stamp()) pill \(mode)"); fflush(stdout) }
            // Main-thread stalls: anything over 150 ms means the pill and keys were held up.
            var last = Date()
            Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
                let gap = Date().timeIntervalSince(last)
                if gap > 0.15 { print("\(stamp()) main thread stalled \(Int(gap * 1000)) ms"); fflush(stdout) }
                last = Date()
            }
            for token in script.split(separator: " ") {
                let t = String(token)
                let kind = t.prefix { $0.isLetter }
                let rest = t.dropFirst(kind.count)
                let ms = Double(rest.prefix { $0.isNumber }) ?? 0
                let words = rest.drop { $0.isNumber }.replacingOccurrences(of: "_", with: " ")
                DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) {
                    let now = ProcessInfo.processInfo.systemUptime
                    switch kind {
                    case "d": print("\(stamp()) fn down"); self.fnMonitor.inject(fnDown: true, at: now)
                    case "u": print("\(stamp()) fn up"); self.fnMonitor.inject(fnDown: false, at: now)
                    case "s":
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                        p.arguments = [String(words)]
                        try? p.run()
                    case "end": fflush(stdout); NSApp.terminate(nil)
                    default: break
                    }
                    fflush(stdout)
                }
            }
        }
    }

    /// Cycles the pill through its states, for screenshots and design review: `Utter --demo-pill`.
    /// `SpeechKey --test-paste`: the paste confirmation, without touching the keyboard. This process
    /// plays the focused app: once it reads the text, once it never does. Sean's clipboard is put
    /// back at the end.
    @MainActor private func runPasteTest() {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = pb.pasteboardItems?.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { dict[type] = d } }
            return dict
        } ?? []
        let before = pb.string(forType: .string)
        let paster = Paster()
        paster.postsKeystroke = false
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "ok    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }
        let started = Date()
        paster.paste("Speech Key paste test one") { result in
            check(result == .landed, String(format: "read after 0.1 s: %@ after %.2f s", "\(result)", Date().timeIntervalSince(started)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            check(pb.string(forType: .string) == "Speech Key paste test one", "the reader got the text")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            check(pb.string(forType: .string) == before, "the old clipboard is back after a read")
            let second = Date()
            paster.paste("Speech Key paste test two") { result in
                check(result == .missed, String(format: "no read: %@ after %.2f s", "\(result)", Date().timeIntervalSince(second)))
                check(pb.string(forType: .string) == "Speech Key paste test two", "the text stays on the clipboard for ⌘V")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
            pb.clearContents()
            pb.writeObjects(saved.map { dict in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            })
            check(pb.string(forType: .string) == before, "Sean's clipboard restored")
            print(failures == 0 ? "paste test passed" : "paste test: \(failures) failed")
            NSApp.terminate(nil)
        }
    }

    @MainActor private func runPillDemo() {
        let pill = controller.pill
        let steps: [(PillModel.Mode, Double)] = [
            (.listening, 2.5), (.working, 1.5), (.done("Fixed NOVA, Tighe"), 1.5),
            (.handsFree, 3.0), (.working, 1.2), (.done("Pasted"), 1.4), (.message("Didn't catch that"), 1.4), (.hidden, 0.5),
        ]
        var t = 0.0
        for (mode, duration) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                if mode == .hidden { pill.hide() } else { pill.show(mode) }
            }
            t += duration
        }
        // Fake a voice on the bars while listening.
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            let e = Date().timeIntervalSince(start)
            if e > t { timer.invalidate(); NSApp.terminate(nil); return }
            let v = Float(0.35 + 0.35 * sin(e * 9) * sin(e * 2.3) + Double.random(in: 0...0.25))
            MainActor.assumeIsolated { pill.model.push(level: max(0, v)) }
        }
    }

    /// The event tap only works once the key permission is granted, so keep trying until it is.
    @MainActor private func startKeyMonitor() {
        if Permissions.keys, fnMonitor.start() { return }
        Permissions.promptKeys()
        accessibilityPoll?.invalidate()
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, Permissions.keys, self.fnMonitor.start() else { return }
                timer.invalidate()
                self.refreshIcon()
            }
        }
    }

    @MainActor private func refreshIcon() {
        guard let button = statusItem.button else { return }
        panel?.model.meetingStartedAt = meeting?.startedAt
        if meeting?.isRunning == true {
            // Recording: a red dot and the elapsed time, so it's obvious a meeting is being transcribed.
            statusItem.length = NSStatusItem.variableLength
            button.image = nil
            let red = NSColor.systemRed
            let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: red, .font: NSFont.systemFont(ofSize: 12)])
            title.append(NSAttributedString(string: MeetingTranscript.clock(meeting.elapsed),
                                            attributes: [.foregroundColor: red,
                                                         .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]))
            button.attributedTitle = title
            return
        }
        statusItem.length = NSStatusItem.squareLength
        button.attributedTitle = NSAttributedString(string: "")
        let name: String
        if case .failed = controller.engineState { name = "exclamationmark.triangle" } else { name = "waveform" }
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "SpeechKey")
        button.image?.isTemplate = true
    }

    // MARK: - Panel

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        panel.toggle(from: button)
    }

    @MainActor private func makePanelModel(brain: CommandBrain) -> PanelModel {
        let model = PanelModel(history: history, glossary: glossaryStore)
        model.meetingsRoot = meeting.root
        model.brainStatus = brain.unavailableReason ?? "\(brain.name) · ready"
        model.actions = PanelModel.Actions(
            startMeeting: { [weak self] in self?.meeting.start() },
            endMeeting: { [weak self] in self?.meeting.end() },
            snapshot: { [weak self] in self?.meeting.snapshot() },
            openMeetingsFolder: { [weak self] in self?.meeting.openFolder() },
            openGlossary: { NSWorkspace.shared.open(URL(fileURLWithPath: UtterPaths.glossary)) },
            openLog: { Self.revealLog() },
            showSetup: { [weak self] in self?.panel.close(); self?.setup.show() },
            setLaunchAtLogin: { [weak self] on in self?.setLaunchAtLogin(on) },
            chooseGlossary: { [weak self] in self?.chooseGlossary() },
            chooseMeetingsFolder: { [weak self] in self?.chooseMeetingsFolder() },
            quit: { NSApp.terminate(nil) },
            close: { [weak self] in self?.panel.close() })
        return model
    }

    /// Fresh state each time the panel opens. Cheap: a few directory listings and the glossary file.
    @MainActor private func refreshPanel() {
        let m = panel.model
        m.meetingStartedAt = meeting.startedAt
        m.meetingsRoot = meeting.root
        m.refreshMeetings()
        glossaryStore.refresh()
        m.glossaryTermCount = controller.currentGlossary().terms.count
        m.launchAtLogin = SMAppService.mainApp.status == .enabled
        m.glossaryPathLabel = Self.tilde(glossaryStore.path)
        m.meetingsPathLabel = Self.tilde(UtterPaths.meetings.path)
        m.brainStatus = commands.brain.unavailableReason ?? "\(commands.brain.name) · ready"
        switch controller.engineState {
        case .loading: m.status = "Loading speech model…"; m.statusColor = .systemOrange
        case .failed(let why): m.status = "Speech model failed: \(why)"; m.statusColor = .systemRed
        case .ready:
            m.status = Permissions.keys ? "Ready" : "Needs \(Permissions.keysPaneName) to hear fn"
            m.statusColor = Permissions.keys ? .systemGreen : .systemOrange
        }
        m.isReady = controller.engineState == .ready && Permissions.keys
        var problems: [PanelModel.Problem] = []
        if !Permissions.keys {
            problems.append(.init(id: "ax", text: "Speech Key needs \(Permissions.keysPaneName) to hear fn.", button: "Open Settings") {
                Permissions.openKeysSettings()
            })
        }
        if Permissions.keys && !Permissions.paste {
            problems.append(.init(id: "paste", text: "Allow Speech Key under Accessibility to paste; until then it copies.", button: "Open Settings") {
                Permissions.openAccessibilitySettings()
            })
        }
        if Permissions.mic != .granted {
            problems.append(.init(id: "mic", text: "Speech Key needs the microphone.", button: "Allow") {
                if Permissions.mic == .notAsked { Permissions.requestMic { _ in } } else { Permissions.openMicrophoneSettings() }
            })
        }
        if !Permissions.globeKeyDoesNothing {
            problems.append(.init(id: "globe", text: "Set “Press 🌐 key to” Do Nothing, or fn also opens emoji.", button: "Open Settings") {
                Permissions.openKeyboardSettings()
            })
        }
        m.problems = problems
    }

    private static func tilde(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }

    /// Point Utter at another glossary file, such as one shared with other tools.
    @MainActor private func chooseGlossary() {
        let open = NSOpenPanel()
        open.title = "Choose a glossary file"
        open.allowedContentTypes = [.init(filenameExtension: "md")!, .plainText]
        open.directoryURL = URL(fileURLWithPath: glossaryStore.path).deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, let url = open.url else { return }
        UtterPaths.setGlossary(url.path)
        glossaryStore.use(path: url.path)
        refreshPanel()
    }

    @MainActor private func chooseMeetingsFolder() {
        let open = NSOpenPanel()
        open.title = "Choose where meeting transcripts go"
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.directoryURL = UtterPaths.meetings.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, let url = open.url else { return }
        UtterPaths.setMeetings(url)
        panel.model.meetingsRoot = url
        refreshPanel()
    }

    private static func revealLog() {
        let url = DictationLog.file
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            try? FileManager.default.createDirectory(at: DictationLog.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(DictationLog.directory)
        }
    }

    @MainActor private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            panel.model.showToast("Couldn’t change Launch at Login: \(error.localizedDescription)")
        }
        panel.model.launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
