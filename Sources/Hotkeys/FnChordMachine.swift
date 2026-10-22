import Foundation

/// Decides what a press of fn means, from the modifier keys held with it. No AppKit, so the
/// rules can be tested with plain key sequences.
///
/// The chords:
/// - fn alone: hold to dictate; double-tap for hands-free dictation, tap fn again to finish.
/// - ⇧ fn: hold to talk to the agent.
/// - ⇧⌃⌥ fn: talk to Utter hands-free; tap fn again to finish.
/// - ⌃⌥ fn: start or end a meeting.
/// - ⌃ fn: meeting snapshot.
///
/// ⌃ fn is part of ⌃⌥ fn, so a chord counts when fn comes up: every modifier held at any point
/// during the press is part of it. The keys can go down in any order.
///
/// Recording starts the moment a press could be a recording (fn alone, or with ⇧), so the
/// first word isn't lost; it's thrown away if the chord turns out to be something else.
public struct FnChordMachine: Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public enum Recording: Equatable, Sendable {
        /// Text pasted where the cursor is.
        case dictation
        /// Spoken to Utter itself.
        case command
    }

    public enum Output: Equatable, Sendable {
        case startRecording(Recording)
        case cancelRecording
        /// A hold ended, or hands-free was finished: process what was recorded.
        case finishRecording
        /// Keep the current recording going after fn comes up; the next fn press finishes it.
        case keepRecordingHandsFree
        case snapshot
        case toggleMeeting
    }

    public static let commandChord: Modifiers = [.shift]
    public static let handsFreeCommandChord: Modifiers = [.shift, .control, .option]
    public static let meetingChord: Modifiers = [.control, .option]
    public static let snapshotChord: Modifiers = [.control]

    public var minHold: TimeInterval = 0.3
    public var doubleTapWindow: TimeInterval = 0.45

    private struct Press {
        var since: TimeInterval
        var modifiers: Modifiers
        var recording: Recording?
        var otherKey = false
    }

    private enum State {
        case idle
        case pressing(Press)
        case handsFree
        case handsFreeFnDown
    }

    private var state: State = .idle
    private var lastTapEnd: TimeInterval = -.infinity

    public init() {}

    public var isRecording: Bool {
        switch state {
        case .idle: return false
        case .pressing(let p): return p.recording != nil
        case .handsFree, .handsFreeFnDown: return true
        }
    }

    /// Forget any in-progress press (after the app finishes or cancels on its own).
    public mutating func reset() { state = .idle }

    public mutating func fnDown(modifiers: Modifiers, at time: TimeInterval) -> [Output] {
        switch state {
        case .idle:
            var press = Press(since: time, modifiers: modifiers)
            let out = reconcile(&press)
            state = .pressing(press)
            return out
        case .handsFree:
            state = .handsFreeFnDown
            return []
        case .pressing, .handsFreeFnDown:
            return []
        }
    }

    /// A modifier went down or up while fn is held. Only additions matter.
    public mutating func modifiersChanged(_ modifiers: Modifiers) -> [Output] {
        guard case .pressing(var press) = state else { return [] }
        press.modifiers.formUnion(modifiers)
        let out = reconcile(&press)
        state = .pressing(press)
        return out
    }

    /// A non-modifier key (fn+Delete, fn+arrow): this press isn't for Utter.
    public mutating func otherKeyDown() -> [Output] {
        guard case .pressing(var press) = state, !press.otherKey else { return [] }
        press.otherKey = true
        let out: [Output] = press.recording == nil ? [] : [.cancelRecording]
        press.recording = nil
        state = .pressing(press)
        return out
    }

    /// Esc. Returns `[.cancelRecording]` when it cancelled something (so the caller swallows the key).
    public mutating func escape() -> [Output] {
        guard isRecording else { return [] }
        if case .pressing(var press) = state {
            press.recording = nil
            press.otherKey = true
            state = .pressing(press)
        } else {
            state = .idle
        }
        return [.cancelRecording]
    }

    public mutating func fnUp(at time: TimeInterval) -> [Output] {
        switch state {
        case .handsFreeFnDown:
            state = .idle
            return [.finishRecording]
        case .pressing(let press):
            state = .idle
            return release(press, at: time)
        case .idle, .handsFree:
            return []
        }
    }

    private mutating func release(_ press: Press, at time: TimeInterval) -> [Output] {
        let cancel: [Output] = press.recording == nil ? [] : [.cancelRecording]
        let chord = press.modifiers
        let held = time - press.since
        if chord != [] { lastTapEnd = -.infinity }
        if press.otherKey { return cancel }

        switch chord {
        case []:
            guard held < minHold else { return [.finishRecording] }
            if time - lastTapEnd < doubleTapWindow {
                lastTapEnd = -.infinity
                state = .handsFree
                return [.keepRecordingHandsFree]
            }
            lastTapEnd = time
            return cancel
        case Self.commandChord:
            return held < minHold ? cancel : [.finishRecording]
        case Self.handsFreeCommandChord:
            state = .handsFree
            return [.keepRecordingHandsFree]
        case Self.meetingChord:
            return cancel + [.toggleMeeting]
        case Self.snapshotChord:
            return cancel + [.snapshot]
        default:
            return cancel
        }
    }

    /// Starts, switches or stops the speculative recording to match the chord so far.
    private func reconcile(_ press: inout Press) -> [Output] {
        let want = press.otherKey ? nil : Self.recording(for: press.modifiers)
        guard want != press.recording else { return [] }
        var out: [Output] = []
        if press.recording != nil { out.append(.cancelRecording) }
        if let want { out.append(.startRecording(want)) }
        press.recording = want
        return out
    }

    static func recording(for modifiers: Modifiers) -> Recording? {
        if modifiers.isEmpty { return .dictation }
        if modifiers.contains(.shift), modifiers.isSubset(of: handsFreeCommandChord) { return .command }
        return nil
    }
}
