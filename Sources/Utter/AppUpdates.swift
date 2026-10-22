import AppKit
#if !APPSTORE
import Sparkle
#endif

/// Updates for the website build: Sparkle checks speechkeyapp.com/appcast.xml once a day and
/// offers new versions, signed with the EdDSA key whose public half is in Info.plist. The App
/// Store build has none of this; the Store updates it.
@MainActor
enum AppUpdates {
    #if APPSTORE
    static let available = false
    static func start() {}
    static func checkNow() {}
    #else
    static let available = true
    private static var controller: SPUStandardUpdaterController?

    static func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// The "Check for Updates…" button. A menu-bar app has no windows in front, so come forward first.
    static func checkNow() {
        start()
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
    #endif
}
