import AppKit

// Text reports that need no app: `SpeechKey --cleanup-report [days]`, `SpeechKey --cleanup-replay [kinds]`.
if CleanupReport.runIfAsked(CommandLine.arguments) { exit(0) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
