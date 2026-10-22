import AppKit
import CoreGraphics
import Hotkeys

/// What a press of fn means, decided by `FnChordMachine`.
@MainActor
protocol FnKeyMonitorDelegate: AnyObject {
    /// Start recording now so the first word isn't lost.
    func startRecording(_ kind: FnChordMachine.Recording)
    /// It was a tap, or a chord that isn't a recording: throw the recording away quietly.
    func cancelRecording()
    /// A hold ended, or hands-free was finished: process what was recorded.
    func finishRecording()
    /// Keep recording after fn comes up; the next fn tap finishes.
    func keepRecordingHandsFree()
    /// Esc while recording: discard, and say so.
    func escapePressed()
}

/// Watches the keyboard with a Core Graphics event tap (needs Accessibility permission) and feeds
/// fn and modifier events to `FnChordMachine`, which holds the rules.
///
/// - Any other key pressed while fn is held (fn+Delete, fn+arrow) cancels quietly.
/// - Esc cancels a recording and is swallowed so it doesn't also close something.
@MainActor
final class FnKeyMonitor {
    weak var delegate: FnKeyMonitorDelegate?
    /// ⌃ fn: meeting snapshot.
    var onSnapshot: (() -> Void)?
    /// ⌃⌥ fn: start or end a meeting.
    var onToggleMeeting: (() -> Void)?

    private var machine = FnChordMachine()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?

    static let fnKeyCode: Int64 = 63
    static let escapeKeyCode: Int64 = 53

    var isRecording: Bool { machine.isRecording }

    /// Returns false if the tap couldn't be created (no Accessibility permission yet).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // The tap's run-loop source is on the main run loop, so this is the main thread.
            return MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // macOS switches a tap off if it ever answers too slowly, and the notice can be missed.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTap() }
        }
        return true
    }

    private func checkTap() {
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        UtterLog.write("key tap was off; turned it back on")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Feeds a scripted fn press to the same rules, for tests (`--simulate-keys`).
    func inject(fnDown: Bool, modifiers: FnChordMachine.Modifiers = [], at time: TimeInterval) {
        dispatch(fnDown ? machine.fnDown(modifiers: modifiers, at: time) : machine.fnUp(at: time))
    }

    /// Forget any in-progress press (after the app finishes or cancels on its own).
    func reset() { machine.reset() }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            UtterLog.write(type == .tapDisabledByTimeout ? "key tap timed out; turned it back on" : "key tap paused by macOS; turned it back on")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.escapeKeyCode {
                let out = machine.escape()
                guard !out.isEmpty else { return pass }
                DispatchQueue.main.async { [weak self] in self?.delegate?.escapePressed() }
                return nil
            }
            dispatch(machine.otherKeyDown())
            return pass
        case .flagsChanged:
            let flags = event.flags
            let modifiers = Self.modifiers(flags)
            // When the key actually moved, not when this callback got to it: after a stall, queued
            // events arrive together and would otherwise look like zero-length taps.
            let at = Self.eventTime(event.timestamp)
            if event.getIntegerValueField(.keyboardEventKeycode) == Self.fnKeyCode {
                dispatch(flags.contains(.maskSecondaryFn) ? machine.fnDown(modifiers: modifiers, at: at) : machine.fnUp(at: at))
            } else {
                dispatch(machine.modifiersChanged(modifiers))
            }
            return pass
        default:
            return pass
        }
    }

    /// The rules decide at once; the work (opening the mic, the pill) runs right after the tap
    /// callback returns, so the keyboard is never held up waiting for it.
    private func dispatch(_ outputs: [FnChordMachine.Output]) {
        guard !outputs.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.run(outputs) }
    }

    /// An event's timestamp as system uptime. CGEvent timestamps are nanoseconds on some Macs and
    /// mach ticks on others; take whichever reading puts the event in the last minute.
    static func eventTime(_ stamp: UInt64) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        let ticksNow = mach_absolute_time()
        let ageIfTicks = (Double(ticksNow) - Double(stamp)) * Double(base.numer) / Double(base.denom) / 1e9
        let ageIfNanos = now - Double(stamp) / 1e9
        for age in [ageIfTicks, ageIfNanos] where age >= 0 && age < 60 { return now - age }
        return now
    }

    private func run(_ outputs: [FnChordMachine.Output]) {
        for output in outputs {
            switch output {
            case .startRecording(let kind): delegate?.startRecording(kind)
            case .cancelRecording: delegate?.cancelRecording()
            case .finishRecording: delegate?.finishRecording()
            case .keepRecordingHandsFree: delegate?.keepRecordingHandsFree()
            case .snapshot: onSnapshot?()
            case .toggleMeeting: onToggleMeeting?()
            }
        }
    }

    private static func modifiers(_ flags: CGEventFlags) -> FnChordMachine.Modifiers {
        var m: FnChordMachine.Modifiers = []
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        return m
    }
}
