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

    /// `SpeechKey --test-update-check`: asks the feed whether a newer version exists and prints the
    /// answer, without showing anything or installing.
    private static var probeUpdater: SPUUpdater?
    static func probe() {
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil), delegate: ProbeDelegate.shared)
        probeUpdater = updater
        do { try updater.start() } catch { print("updater failed to start: \(error)"); NSApp.terminate(nil); return }
        print("this copy: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?"), feed: \(updater.feedURL?.absoluteString ?? "none")")
        updater.checkForUpdateInformation()
    }

    private final class ProbeDelegate: NSObject, SPUUpdaterDelegate {
        static let shared = ProbeDelegate()
        func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            print("update found: \(item.displayVersionString) (build \(item.versionString)), \(item.fileURL?.absoluteString ?? "")")
            NSApp.terminate(nil)
        }
        func updaterDidNotFindUpdate(_ updater: SPUUpdater) { print("no update: this is the newest"); NSApp.terminate(nil) }
        func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
            print("check failed: \(error.localizedDescription)"); NSApp.terminate(nil)
        }
    }
    #endif
}
