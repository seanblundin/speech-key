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

    /// Needed for the fn-key event tap and for pasting.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "allow Accessibility" prompt (once per app identity).
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
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
