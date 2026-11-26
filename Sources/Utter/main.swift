import AppKit

// Text reports that need no app: `SpeechKey --cleanup-report [days]`, `SpeechKey --cleanup-replay [kinds]`.
if CleanupReport.runIfAsked(CommandLine.arguments) { exit(0) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // A normal app with a Dock icon and its running dot, so it's plain when Speech Key is open
    // (Sean, 2026-11-26: "rather than being some background process that's kind of elusive").
    // Test modes (any "--" argument) stay out of the Dock.
    let testRun = CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
    app.setActivationPolicy(testRun ? .accessory : .regular)
    app.run()
}
