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
    /// The app that was in front before Speech Key's panel or setup window took focus.
    private var appBefore: NSRunningApplication?

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
        let testing = args.contains { $0.hasPrefix("--simulate") || $0 == "--render-pill" || $0 == "--test-meeting" || $0 == "--test-voices" || $0 == "--test-line-voices" || $0 == "--test-paste" || $0 == "--test-titles" || $0 == "--test-update-check" || $0 == "--give-codes" || $0 == "--verify-models" }
        if testing { controller.log.enabled = false }
        fnMonitor = FnKeyMonitor()
        setup = SetupWindowController()
        setup.engineState = { [weak self] in self?.controller.engineState ?? .loading }
        setup.download = { [weak self] in self?.controller.downloadProgress }
        setup.iconHidden = { [weak self] in self?.menuBarIconHidden ?? false }
        setup.onClose = { [weak self] in self?.giveFocusBack() }
        setup.onAllDone = { [weak self] in
            self?.controller.pill.show(.message("Ready · hold 🌐 and talk"), autoHideAfter: 2.5)
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
                controller.pill.show(.done("I closed mid-meeting, but it's all saved"), autoHideAfter: 4)
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
        controller.onLesson = { [weak self] in self?.glossaryStore.learn($0) ?? false }
        controller.onCommand = { [weak self] text, raw in self?.commands.run(text, raw: raw) }
        panel = PanelController(model: makePanelModel(brain: brain))
        panel.model.titler = titler
        titler.onUpdate = { [weak self] in self?.panel?.model.refreshMeetings() }
        panel.willOpen = { [weak self] in self?.rememberAppInFront(); self?.refreshPanel() }
        panel.didClose = { [weak self] in self?.giveFocusBack() }
        if !testing { NSApp.mainMenu = makeMainMenu(); watchAppInFront() }
        // Remote control, so Claude can take a snapshot or end a meeting on Sean's behalf:
        //   com.seanblundin.utter.meeting.snapshot / .end
        // There is no remote "start": any app can post these, and starting turns on the mic.
        // Off unless turned on (`defaults write com.seanblundin.utter remoteMeetingControl -bool true`,
        // as on Sean's Mac), so other apps can't end or snapshot anyone else's meetings (2026-10-25).
        // Never in the App Store build.
        #if !APPSTORE
        if UserDefaults.standard.bool(forKey: "remoteMeetingControl") {
        // `.deliverImmediately`, so they arrive while the app is in the background, which for a
        // menu bar app is nearly always. Each one is logged, to show whether remote control is on.
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(remoteSnapshot), name: Notification.Name("com.seanblundin.utter.meeting.snapshot"),
                           object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(remoteEnd), name: Notification.Name("com.seanblundin.utter.meeting.end"),
                           object: nil, suspensionBehavior: .deliverImmediately)
        UtterLog.write("remote meeting control on")
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
        if let folder = arg("--test-line-voices") {
            // Experiment: fingerprint each transcript line of a kept meeting on its own and compare it
            // with the user's voice, instead of asking a model to find the turns.
            Task {
                let dir = URL(fileURLWithPath: folder)
                guard let tape = try? SpeechEngine.loadAudioFile(dir.appendingPathComponent(StreamTape.mic)),
                      let log = try? String(contentsOf: dir.appendingPathComponent(MeetingRecovery.doneName), encoding: .utf8) else { print("can't read \(folder)"); NSApp.terminate(nil); return }
                // The user's voice, from kept dictations, with the same fingerprinter.
                var mine = [Float](repeating: 0, count: 256)
                var used = 0
                let kept = ((try? FileManager.default.contentsOfDirectory(at: AudioKeep.folder, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
                for f in kept where used < 16 {
                    guard let clip = try? SpeechEngine.loadAudioFile(f), clip.count >= 4 * 16_000, clip.count <= 300 * 16_000,
                          let p = try? await SpeakerSplitter.shared.fingerprint(Array(clip.dropFirst(8_000))) else { continue }
                    for i in mine.indices { mine[i] += p[i] }
                    used += 1
                }
                mine = VoiceLabels.unit(mine)
                print("voiceprint from \(used) dictations")
                var prints: [(start: Double, end: Double, text: String, print: [Float])] = []
                for line in log.split(separator: "\n") {
                    guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let text = o["text"] as? String, let start = o["start"] as? Double, let end = o["end"] as? Double else { continue }
                    // At least 1.2 s of audio, centred on the line.
                    let pad = max(0, (1.2 - (end - start)) / 2)
                    let a = max(0, Int((start - pad) * 16_000)), b = min(tape.count, Int((end + pad) * 16_000))
                    guard b > a, let p = try? await SpeakerSplitter.shared.fingerprint(Array(tape[a..<b])) else { continue }
                    prints.append((start, end, text, p))
                }
                for (i, l) in prints.enumerated() {
                    let prev = i > 0 ? VoiceLabels.similarity(l.print, prints[i - 1].print) : 0
                    print(String(format: "%6.1f %4.1fs  me %5.2f  prev %5.2f  %@", l.start, l.end - l.start, VoiceLabels.similarity(l.print, mine), prev, String(l.text.prefix(80))))
                }
                if let out = arg("--dump") {
                    let rows = prints.map { ["start": $0.start, "end": $0.end, "text": $0.text, "print": $0.print] as [String: Any] }
                    try? JSONSerialization.data(withJSONObject: ["mine": mine, "lines": rows]).write(to: URL(fileURLWithPath: out))
                }
                fflush(stdout)
                NSApp.terminate(nil)
            }
            return
        }
        if let file = arg("--test-voices") {
            // SpeechKey --test-voices mic.wav [--call call.wav]: treat recordings as the two streams
            // of a meeting. Transcribes them the way a meeting does, tells the voices apart, prints
            // the transcript. With no --call it is a mic-only meeting.
            controller.loadEngine()
            Task {
                guard let engine = await controller.sharedEngine() else { print("no engine"); NSApp.terminate(nil); return }
                var transcript = MeetingTranscript(startedAt: Date())
                let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("speechkey-test-voices-\(getpid())")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var tapes: [String: StreamTape] = [:]
                var length = 0.0
                for (stream, path, name) in [(MeetingTranscript.me, file, StreamTape.mic), (MeetingTranscript.them, arg("--call") ?? "", StreamTape.call)] where !path.isEmpty {
                    guard let samples = try? SpeechEngine.loadAudioFile(URL(fileURLWithPath: path)), let chunker = try? await PauseChunker.make(),
                          let tape = StreamTape(folder: folder, name: name) else { print("can't read \(path)"); NSApp.terminate(nil); return }
                    var chunks: [PauseChunker.Chunk] = []
                    var i = 0
                    while i < samples.count {
                        let piece = Array(samples[i..<min(i + 16_000, samples.count)])
                        tape.append(piece)       // the same recording a live meeting writes
                        chunks += (try? await chunker.append(piece)) ?? []
                        i += 16_000
                        if i == 16_000 * (samples.count / 32_000) { _ = tape.seal() }   // sealed part-way, like a snapshot
                    }
                    if let tail = await chunker.flush() { chunks.append(tail) }
                    for chunk in chunks where chunk.hasSpeech && chunk.samples.count >= SpeechEngine.minimumSamples {
                        for seg in (try? await engine.transcribe(samples: chunk.samples, vocabulary: [], priority: .interactive)) ?? [] {
                            transcript.add(.init(speaker: stream, start: chunk.start + seg.start, end: chunk.start + seg.end, text: seg.text))
                        }
                    }
                    print(String(format: "%@: %.1fs on tape", stream, tape.seal()))
                    tapes[stream] = tape
                    length = max(length, Double(samples.count) / 16_000)
                }
                _ = transcript.makePart(endingAt: length)
                defer { tapes.values.forEach { $0.close(keep: false) }; try? FileManager.default.removeItem(at: folder) }
                do {
                    let result = try await MeetingVoices.name(transcript, tapes: tapes.mapValues(\.url), previous: [:])
                    transcript.setVoices(result.names, on: result.streams)
                    for (stream, share) in result.unheard { print(String(format: "left %@ as it is: no voice found for %.0f%% of its words", stream, share * 100)) }
                    print(String(format: "voices told apart in %.1fs for %.1f min: %@", result.seconds, length / 60,
                                 Set(result.names.values).sorted().joined(separator: ", ")))
                } catch { print("couldn't tell voices apart: \(error)") }
                print(transcript.fullMarkdown(now: length))
                fflush(stdout)
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
            rememberAppInFront()
            setup.show()
        } else {
            // Opened at login or by hand with nothing to show: don't sit in front of the app the
            // user is working in, or their next dictation would have nowhere to land.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, NSApp.isActive, !self.panel.isOpen, !self.setup.isVisible else { return }
                if let before = self.appBefore { before.activate() } else { NSApp.deactivate() }
            }
        }
    }

    // MARK: - Dock and menus

    /// Clicking the Dock icon (or opening the app again) shows the panel, hanging from the
    /// menu-bar icon when there is one, so people learn where it lives.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if setup.isVisible { NSApp.activate(ignoringOtherApps: true); return }
            if panel.isOpen { panel.close(); return }      // a second click puts it away, like the menu-bar icon
            if let button = statusItem?.button, !menuBarIconHidden { panel.open(from: button) } else { panel.openWithoutIcon() }
        }
        return false
    }

    /// The menu bar is too full to show the icon. macOS keeps laying icons out to the left, under
    /// the notch and off the screen, with no sign that any are missing (measured 2026-11-26).
    private var menuBarIconHidden: Bool {
        guard let window = statusItem?.button?.window, let screen = window.screen ?? NSScreen.main else { return false }
        if let rightOfNotch = screen.auxiliaryTopRightArea { return window.frame.minX < rightOfNotch.minX - 1 }
        return window.frame.minX < screen.frame.minX
    }

    private func rememberAppInFront() {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            appBefore = front
        }
    }

    /// Keeps `appBefore` current: a Dock click brings Speech Key to the front before any of its code
    /// runs, so by then it is too late to ask who was in front.
    private func watchAppInFront() {
        rememberAppInFront()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.appBefore = app }
        }
    }

    /// When the panel or setup window closes and Speech Key is still the app in front, hands focus
    /// back, so the next dictation lands where the user was working. (A menu-bar-only app got this
    /// from macOS for free; an app in the Dock stays in front with no window.)
    private func giveFocusBack() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, NSApp.isActive, !self.panel.isOpen, !self.setup.isVisible,
                  !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            self.appBefore?.activate()
        }
    }

    /// The standard menus an app in the Dock is expected to have. Edit also makes ⌘C, ⌘V, ⌘X and
    /// ⌘A work in the panel's text fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = target
            return i
        }
        add("Speech Key", [
            item("About Speech Key", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Open Speech Key", #selector(openPanelFromMenu), "o", target: self),
            item("Setup…", #selector(openSetupFromMenu), target: self),
            .separator(),
            item("Hide Speech Key", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit Speech Key", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        add("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }

    @objc private func openPanelFromMenu() { _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) }
    @objc private func openSetupFromMenu() { panel.close(); rememberAppInFront(); setup.show() }

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + Paster.confirmWithin + 0.5) {
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

    @objc private func remoteSnapshot() { UtterLog.write("remote: snapshot"); meeting.snapshot() }
    @objc private func remoteEnd() { UtterLog.write("remote: end"); meeting.end() }

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
            showSetup: { [weak self] in self?.panel.close(); self?.rememberAppInFront(); self?.setup.show() },
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
        if menuBarIconHidden {
            problems.append(.init(id: "icon", text: "Your menu bar is full, so my icon is hidden. Hold ⌘ and drag an icon you don’t need off the bar; I’m quickest to reach from there.",
                                  button: "Menu Bar Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
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
