import Testing
@testable import Hotkeys

struct FnChordMachineTests {
    typealias M = FnChordMachine.Modifiers

    @Test func holdFnDictates() {
        var m = FnChordMachine()
        #expect(m.fnDown(modifiers: [], at: 0) == [.startRecording(.dictation)])
        #expect(m.fnUp(at: 1.0) == [.finishRecording])
        #expect(!m.isRecording)
    }

    @Test func doubleTapGoesHandsFreeAndATapFinishes() {
        var m = FnChordMachine()
        _ = m.fnDown(modifiers: [], at: 0)
        #expect(m.fnUp(at: 0.1) == [.cancelRecording])
        #expect(m.fnDown(modifiers: [], at: 0.25) == [.startRecording(.dictation)])
        #expect(m.fnUp(at: 0.35) == [.keepRecordingHandsFree])
        #expect(m.isRecording)
        #expect(m.fnDown(modifiers: [], at: 5) == [])
        #expect(m.fnUp(at: 5.1) == [.finishRecording])
        #expect(!m.isRecording)
    }

    @Test func shiftHoldTalksToUtter() {
        var m = FnChordMachine()
        #expect(m.fnDown(modifiers: [.shift], at: 0) == [.startRecording(.command)])
        #expect(m.fnUp(at: 2) == [.finishRecording])
    }

    @Test func shiftAddedAfterFnSwitchesToCommand() {
        var m = FnChordMachine()
        #expect(m.fnDown(modifiers: [], at: 0) == [.startRecording(.dictation)])
        #expect(m.modifiersChanged([.shift]) == [.cancelRecording, .startRecording(.command)])
        #expect(m.fnUp(at: 2) == [.finishRecording])
    }

    @Test func shiftTapIsIgnored() {
        var m = FnChordMachine()
        _ = m.fnDown(modifiers: [.shift], at: 0)
        #expect(m.fnUp(at: 0.1) == [.cancelRecording])
    }

    @Test func allFourKeysGoHandsFreeToUtterInAnyOrder() {
        // fn first, then the others one by one.
        var m = FnChordMachine()
        #expect(m.fnDown(modifiers: [], at: 0) == [.startRecording(.dictation)])
        #expect(m.modifiersChanged([.control]) == [.cancelRecording])
        #expect(m.modifiersChanged([.control, .option]) == [])
        #expect(m.modifiersChanged([.control, .option, .shift]) == [.startRecording(.command)])
        #expect(m.fnUp(at: 0.2) == [.keepRecordingHandsFree])
        #expect(m.isRecording)
        _ = m.fnDown(modifiers: [], at: 9)
        #expect(m.fnUp(at: 9.1) == [.finishRecording])

        // Modifiers first, fn last.
        var n = FnChordMachine()
        #expect(n.fnDown(modifiers: [.shift, .control, .option], at: 0) == [.startRecording(.command)])
        #expect(n.fnUp(at: 0.1) == [.keepRecordingHandsFree])
    }

    @Test func controlOptionTogglesTheMeetingWhicheverKeyComesFirst() {
        var m = FnChordMachine()
        _ = m.fnDown(modifiers: [], at: 0)
        #expect(m.modifiersChanged([.control]) == [.cancelRecording])
        #expect(m.modifiersChanged([.control, .option]) == [])
        #expect(m.fnUp(at: 0.15) == [.toggleMeeting])

        var n = FnChordMachine()
        #expect(n.fnDown(modifiers: [.control, .option], at: 0) == [])
        #expect(n.fnUp(at: 0.1) == [.toggleMeeting])
    }

    @Test func controlAloneIsASnapshotButNotWhenOptionJoinsLater() {
        var m = FnChordMachine()
        #expect(m.fnDown(modifiers: [.control], at: 0) == [])
        #expect(m.fnUp(at: 0.1) == [.snapshot])

        // Option joins before fn comes up, so it's the meeting chord, not a snapshot.
        var n = FnChordMachine()
        _ = n.fnDown(modifiers: [.control], at: 0)
        _ = n.modifiersChanged([.control, .option])
        #expect(n.fnUp(at: 0.2) == [.toggleMeeting])
    }

    @Test func modifierReleasedBeforeFnStillCounts() {
        var m = FnChordMachine()
        _ = m.fnDown(modifiers: [.control, .option], at: 0)
        _ = m.modifiersChanged([.control])   // option let go first
        #expect(m.fnUp(at: 0.2) == [.toggleMeeting])
    }

    @Test func otherCombinationsDoNothing() {
        for mods: M in [[.command], [.option], [.shift, .control], [.shift, .command], [.control, .command]] {
            var m = FnChordMachine()
            let down = m.fnDown(modifiers: mods, at: 0)
            let up = m.fnUp(at: 1)
            #expect(!(down + up).contains(.snapshot) && !(down + up).contains(.toggleMeeting) && !(down + up).contains(.finishRecording),
                    "mods \(mods.rawValue)")
        }
    }

    @Test func fnWithAnotherKeyCancels() {
        var m = FnChordMachine()
        _ = m.fnDown(modifiers: [], at: 0)
        #expect(m.otherKeyDown() == [.cancelRecording])
        #expect(m.fnUp(at: 1) == [])

        // fn+Ctrl+arrow tiles a window in macOS; it must not take a snapshot.
        var n = FnChordMachine()
        _ = n.fnDown(modifiers: [.control], at: 0)
        _ = n.otherKeyDown()
        #expect(n.fnUp(at: 0.2) == [])
    }

    @Test func escapeCancelsHoldAndHandsFree() {
        var m = FnChordMachine()
        _ = m.fnDown(modifiers: [], at: 0)
        #expect(m.escape() == [.cancelRecording])
        #expect(m.fnUp(at: 1) == [])

        var n = FnChordMachine()
        _ = n.fnDown(modifiers: [.shift, .control, .option], at: 0)
        _ = n.fnUp(at: 0.1)
        #expect(n.escape() == [.cancelRecording])
        #expect(!n.isRecording)
        #expect(n.escape() == [])
    }

    @Test func aChordBetweenTapsDoesNotCountAsADoubleTap() {
        var m = FnChordMachine()
        _ = m.fnDown(modifiers: [], at: 0)
        _ = m.fnUp(at: 0.1)
        _ = m.fnDown(modifiers: [.control], at: 0.2)
        #expect(m.fnUp(at: 0.25) == [.snapshot])
        _ = m.fnDown(modifiers: [], at: 0.3)
        #expect(m.fnUp(at: 0.4) == [.cancelRecording])
    }
}
