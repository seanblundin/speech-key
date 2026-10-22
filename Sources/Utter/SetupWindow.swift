import AppKit
import SwiftUI

/// First-run checklist. Each row turns green on its own as Sean grants things in System Settings.
@MainActor
final class SetupModel: ObservableObject {
    @Published var mic = false
    @Published var micAsked = false
    @Published var accessibility = false
    @Published var globe = false
    @Published var engine: DictationController.EngineState = .loading

    var allDone: Bool { mic && accessibility && globe && engine == .ready }

    func refresh(engine state: DictationController.EngineState) {
        mic = Permissions.mic == .granted
        micAsked = Permissions.mic != .notAsked
        accessibility = Permissions.accessibility
        globe = Permissions.globeKeyDoesNothing
        engine = state
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.22), Color(red: 0.05, green: 0.05, blue: 0.07)],
                                             startPoint: .top, endPoint: .bottom))
                    Image(systemName: "waveform").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SpeechKey").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("Hold fn and talk. Everything stays on this Mac.").foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                SetupRow(done: model.mic, title: "Microphone",
                         detail: "To hear you. Audio is never saved or sent anywhere.",
                         button: model.mic ? nil : (model.micAsked ? "Open Settings" : "Allow")) {
                    if model.micAsked { Permissions.openMicrophoneSettings() } else { Permissions.requestMic { _ in } }
                }
                Divider().padding(.leading, 38)
                SetupRow(done: model.accessibility, title: "Accessibility",
                         detail: "To notice the fn key and paste where your cursor is.",
                         button: model.accessibility ? nil : "Open Settings") { Permissions.openAccessibilitySettings() }
                Divider().padding(.leading, 38)
                SetupRow(done: model.globe, title: "Globe key set to Do Nothing",
                         detail: "Keyboard → “Press 🌐 key to” → Do Nothing, so fn doesn’t also open emoji.",
                         button: model.globe ? nil : "Open Settings") { Permissions.openKeyboardSettings() }
                Divider().padding(.leading, 38)
                SetupRow(done: model.engine == .ready, title: "Speech model", detail: engineDetail, button: nil) {}
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Hold fn to talk, let go to paste", systemImage: "keyboard")
                    Label("Double-tap fn for hands-free, tap fn to finish", systemImage: "hand.raised")
                    Label("Esc cancels", systemImage: "escape")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button(model.allDone ? "Start talking" : "Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var engineDetail: String {
        switch model.engine {
        case .loading: return "Downloading Parakeet (about 0.5 GB, first launch only)…"
        case .ready: return "Parakeet Ultra on the Neural Engine, ready."
        case .failed(let why): return "Couldn’t load: \(why)"
        }
    }
}

private struct SetupRow: View {
    let done: Bool
    let title: String
    let detail: String
    let button: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(done ? Color.green : Color.secondary)
                .frame(width: 22)
                .animation(.spring(response: 0.3), value: done)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let button { Button(button, action: action) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

@MainActor
final class SetupWindowController {
    let model = SetupModel()
    private var window: NSWindow?
    private var timer: Timer?
    var engineState: () -> DictationController.EngineState = { .loading }
    var onAllDone: (() -> Void)?

    func show() {
        model.refresh(engine: engineState())
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(model: model) { [weak self] in self?.close() })
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasDone = self.model.allDone
                self.model.refresh(engine: self.engineState())
                if !wasDone && self.model.allDone { self.onAllDone?() }
            }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible == true }
}
