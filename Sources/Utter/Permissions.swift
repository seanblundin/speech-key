import AppKit
import AVFoundation
import ApplicationServices

/// Read-only checks of what Utter needs from macOS, plus links to the right Settings panes.
enum Permissions {
    enum Mic { case granted, denied, notAsked }

    static var mic: Mic {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    static func requestMic(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    // The website build uses Accessibility for both hearing fn and pasting (and can swallow Esc).
    // The App Store build can't: the sandbox allows listening to keys (Input Monitoring) and
    // sending ⌘V (its own permission, listed under Accessibility), but not the Accessibility API.

    /// Can hear the fn key.
    static var keys: Bool {
        #if APPSTORE
        CGPreflightListenEventAccess()
        #else
        AXIsProcessTrusted()
        #endif
    }

    /// Can send ⌘V to paste.
    static var paste: Bool {
        #if APPSTORE
        CGPreflightPostEventAccess()
        #else
        AXIsProcessTrusted()
        #endif
    }

    /// The name of the Settings pane that grants `keys`, for messages.
    static var keysPaneName: String {
        #if APPSTORE
        "Input Monitoring"
        #else
        "Accessibility"
        #endif
    }

    /// Shows macOS's own prompts (once per app identity).
    static func promptKeys() {
        #if APPSTORE
        _ = CGRequestListenEventAccess()
        _ = CGRequestPostEventAccess()
        #else
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        #endif
    }

    static func openKeysSettings() {
        #if APPSTORE
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        #else
        openAccessibilitySettings()
        #endif
    }

    /// The system Globe-key action must be "Do Nothing" (0); no app can block it otherwise.
    static var globeKeyDoesNothing: Bool {
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return (value as? Int) == 0
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
