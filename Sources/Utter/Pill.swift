import AppKit
import SwiftUI

/// The small floating capsule at the bottom of the screen.
@MainActor
final class PillModel: ObservableObject {
    enum Mode: Equatable {
        case hidden
        case listening
        case handsFree
        case working
        /// A hands-free recording that has ended and is being transcribed: the same pill, dot
        /// greyed and timer stopped at the recording's length, so it doesn't look like a new one.
        case finishing(TimeInterval)
        case done(String)
        case message(String)
        /// Utter answering something Sean asked it (⇧ fn), not a change it made.
        case reply(String)
    }

    @Published var mode: Mode = .hidden
    @Published var levels: [CGFloat] = Array(repeating: 0, count: PillModel.barCount)
    @Published var startedAt = Date()
    /// Talking to Utter (⇧ fn) rather than dictating: the pill takes Utter's colour and a sparkle,
    /// so it's obvious the words won't be pasted.
    @Published var talkingToUtter = false

    static let utterTint = Color(red: 0.66, green: 0.58, blue: 1.0)

    static let barCount = 11

    func push(level: Float) {
        // Newest level enters in the middle and ripples outward, so the bars feel symmetric.
        var next = levels
        let mid = Self.barCount / 2
        for i in 0..<mid {
            next[i] = levels[i + 1]
            next[Self.barCount - 1 - i] = levels[Self.barCount - 2 - i]
        }
        next[mid] = CGFloat(level)
        levels = next
    }

    func resetLevels() { levels = Array(repeating: 0, count: Self.barCount) }
}

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        ZStack {
            if model.mode != .hidden {
                content
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(white: 0.06).opacity(0.92))
                            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    )
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 10)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: model.mode)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .hidden:
            EmptyView()
        case .listening:
            HStack(spacing: 8) {
                if model.talkingToUtter { Sparkle() }
                Bars(levels: model.levels, idleWave: false, tint: tint)
            }
        case .handsFree:
            HStack(spacing: 10) {
                if model.talkingToUtter { Sparkle() } else { RecordingDot() }
                Bars(levels: model.levels, idleWave: false, tint: tint)
                ElapsedLabel(since: model.startedAt)
                Text("fn")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 5)
                    .frame(height: 17)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                    .help("Tap fn to finish")
            }
        case .working:
            HStack(spacing: 8) {
                if model.talkingToUtter { Sparkle() }
                Bars(levels: model.levels, idleWave: true, tint: tint)
            }
        case .finishing(let elapsed):
            HStack(spacing: 10) {
                if model.talkingToUtter { Sparkle() } else {
                    Circle().fill(Color.white.opacity(0.35)).frame(width: 7, height: 7)
                }
                Bars(levels: model.levels, idleWave: true, tint: tint)
                Text(ElapsedLabel.clock(elapsed))
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
        case .done(let text):
            HStack(spacing: 7) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 0.45, green: 0.9, blue: 0.6))
                Text(text).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
        case .reply(let text):
            HStack(spacing: 7) {
                Sparkle()
                Text(text).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
        case .message(let text):
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    private var tint: Color { model.talkingToUtter ? PillModel.utterTint : .white }
}

private struct Sparkle: View {
    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PillModel.utterTint)
    }
}

/// Bars that follow the mic level, or a slow travelling wave while transcribing.
private struct Bars: View {
    let levels: [CGFloat]
    let idleWave: Bool
    var tint: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !idleWave)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(tint.opacity(idleWave ? 0.6 : 0.95))
                        .frame(width: 3, height: height(i, t))
                }
            }
            .frame(height: 20)
            .animation(.easeOut(duration: 0.09), value: levels)
        }
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        if idleWave {
            let phase = sin(t * 5.5 - Double(i) * 0.55)
            return 4 + CGFloat((phase + 1) / 2) * 7
        }
        // Taper toward the ends so the shape reads as a voice, not an equalizer.
        let center = Double(levels.count - 1) / 2
        let taper = 1 - 0.45 * abs(Double(i) - center) / center
        return max(3, min(20, 3 + levels[i] * 17 * CGFloat(taper)))
    }
}

private struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color(red: 1, green: 0.27, blue: 0.27))
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true } }
    }
}

struct ElapsedLabel: View {
    let since: Date
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Self.clock(context.date.timeIntervalSince(since)))
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// Pill wording (Sean, 2026-10-26: the friendlier proposal, with five changes). Speech Key talks as
/// "I"; the two everyday misses rotate so they don't get stale; anything to act on stays plain.
enum PillWords {
    private static var turn = 0
    /// The next of `lines`, so the same miss doesn't read the same way every time.
    static func rotating(_ lines: [String]) -> String {
        turn += 1
        return lines[turn % lines.count]
    }
    static var nothingHeard: String { rotating(["I missed that one", "Didn't catch that…", "Say that again?"]) }
    static var cancelled: String { rotating(["Never mind", "Scrapped, nothing pasted"]) }
}

/// A borderless, click-through panel that never takes focus, so pasting goes to the app Sean was in.
@MainActor
final class PillController {
    let model = PillModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    /// Tests watch the pill's states through this (`--simulate-keys`).
    var onModeChange: ((PillModel.Mode) -> Void)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func show(_ mode: PillModel.Mode, autoHideAfter delay: TimeInterval? = nil) {
        hideWork?.cancel()
        if mode == .listening || mode == .handsFree {
            if model.mode != .listening && model.mode != .handsFree { model.startedAt = Date() }
            if case .working = model.mode {} else if mode == .listening { model.resetLevels() }
        }
        position()
        panel.orderFrontRegardless()
        if model.mode != mode { onModeChange?(mode) }
        model.mode = mode
        if let delay {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        if model.mode != .hidden { onModeChange?(.hidden) }
        model.mode = .hidden
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.model.mode == .hidden else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Bottom center of the screen Sean is working on (the one with the mouse).
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 8))
    }
}
