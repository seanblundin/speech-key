import Foundation
import Testing
@testable import TranscriptText

struct MeetingTranscriptTests {
    typealias Line = MeetingTranscript.Line

    func sample() -> MeetingTranscript {
        var t = MeetingTranscript(startedAt: Date(timeIntervalSince1970: 0))
        t.add(Line(speaker: "Them", start: 2, end: 6, text: "Hey, can you hear me?"))
        t.add(Line(speaker: "Me", start: 7, end: 9, text: "Yes, loud and clear."))
        t.add(Line(speaker: "Them", start: 400, end: 405, text: "Let's talk budget."))
        t.add(Line(speaker: "Me", start: 745, end: 752, text: "The NOVA numbers look fine."))
        return t
    }

    @Test func partsOverlapByTenSecondsAndAreNamedByElapsedTime() {
        var t = sample()
        let p1 = t.makePart(endingAt: 750)
        #expect(p1.number == 1)
        #expect(p1.fileName == "part-01_00m00-12m30.md")
        let p2 = t.makePart(endingAt: 1625)
        #expect(p2.fileName == "part-02_12m20-27m05.md")
        // The line at 12:25–12:32 straddles the cut, so it appears in both parts.
        #expect(p1.markdown.contains("NOVA"))
        #expect(p2.markdown.contains("NOVA"))
        #expect(!p2.markdown.contains("budget"))
    }

    @Test func finishedMeetingsCountTheirLastPartUnlessItIsTheOnlyOne() {
        // No snapshots taken: the one part saved at the end is just the whole meeting.
        #expect(MeetingTranscript.snapshotCount(parts: 1) == 0)
        // Three taken, then the end saves a fourth.
        #expect(MeetingTranscript.snapshotCount(parts: 4) == 4)
        #expect(MeetingTranscript.snapshotCount(parts: 2) == 2)
        #expect(MeetingTranscript.snapshotCount(parts: 0) == 0)
    }

    @Test func linesAreSortedAndTurnsJoined() {
        var t = MeetingTranscript(startedAt: Date())
        t.add(Line(speaker: "Me", start: 6, end: 8, text: "second"))
        t.add(Line(speaker: "Me", start: 3, end: 5, text: "first"))
        t.add(Line(speaker: "Them", start: 20, end: 22, text: "reply"))
        let md = t.fullMarkdown(now: 30)
        #expect(md.contains("**[0:03] Me:** first second"))
        #expect(md.contains("**[0:20] Them:** reply"))
    }

    @Test func pausesAndLongRunsStartNewParagraphs() {
        var t = MeetingTranscript(startedAt: Date())
        t.add(Line(speaker: "Me", start: 0, end: 4, text: "one"))
        t.add(Line(speaker: "Me", start: 10, end: 12, text: "two"))           // 6 s pause
        for i in 0..<40 { t.add(Line(speaker: "Me", start: 13 + Double(i) * 2, end: 14.5 + Double(i) * 2, text: "w\(i)")) }
        let md = t.fullMarkdown(now: 100)
        #expect(md.contains("**[0:00] Room:** one\n"))
        #expect(md.contains("**[0:10] Room:** two w0"))
        // The run that started at 0:10 is cut before it passes a minute.
        #expect(md.contains("**[1:"))
    }

    @Test func micEchoOfTheCallIsDropped() {
        var t = MeetingTranscript(startedAt: Date())
        t.add(Line(speaker: "Them", start: 10, end: 15, text: "We should ship the pilot next week."))
        t.add(Line(speaker: "Me", start: 10.4, end: 15.2, text: "we should ship the pilot next week"))
        t.add(Line(speaker: "Me", start: 16, end: 18, text: "Agreed, let's do it."))
        let md = t.fullMarkdown(now: 20)
        #expect(md.components(separatedBy: "ship the pilot").count == 2)
        #expect(md.contains("Agreed"))
    }

    @Test func clockFormats() {
        #expect(MeetingTranscript.stamp(750) == "12m30")
        #expect(MeetingTranscript.clock(3725) == "1:02:05")
        #expect(MeetingTranscript.clock(59) == "0:59")
    }

    @Test func shortEchoesAreDroppedButShortRepliesStay() {
        var t = MeetingTranscript(startedAt: Date())
        t.add(Line(speaker: "Them", start: 100, end: 112, text: "They know what they want, it's also typical of clients, and for me that worked."))
        t.add(Line(speaker: "Me", start: 104, end: 105, text: "typical clients."))
        t.add(Line(speaker: "Me", start: 110, end: 111, text: "that worked."))
        t.add(Line(speaker: "Me", start: 113, end: 114, text: "Totally agree."))
        let md = t.fullMarkdown(now: 120)
        #expect(!md.contains("**[1:44] Me:**"))
        #expect(!md.contains("that worked. Totally"))
        #expect(md.contains("Totally agree."))
    }

    @Test func micOnlyMeetingsAreLabeledRoom() {
        var t = MeetingTranscript(startedAt: Date())
        t.add(Line(speaker: "Me", start: 1, end: 3, text: "Thanks for coming in."))
        t.add(Line(speaker: "Me", start: 10, end: 12, text: "Happy to be here."))
        #expect(t.micOnly)
        let md = t.fullMarkdown(now: 20)
        #expect(md.contains("Mic only"))
        #expect(md.contains("**[0:01] Room:**"))
        #expect(!md.contains("Me:"))
        #expect(t.makePart(endingAt: 20).markdown.contains("Room:"))
        t.add(Line(speaker: "Them", start: 14, end: 15, text: "Hello?"))
        #expect(!t.micOnly)
        #expect(t.fullMarkdown(now: 20).contains("**[0:01] Me:**"))
    }

    @Test func voicesGetNamesInAMicOnlyMeeting() {
        typealias Key = MeetingTranscript.LineKey
        var t = MeetingTranscript(startedAt: Date(timeIntervalSince1970: 0))
        t.add(.init(speaker: MeetingTranscript.me, start: 1, end: 4, text: "Let's start with the budget."))
        t.add(.init(speaker: MeetingTranscript.me, start: 5, end: 8, text: "I have the numbers here."))
        t.add(.init(speaker: MeetingTranscript.me, start: 9, end: 12, text: "Great, go ahead."))
        _ = t.makePart(endingAt: 15)
        #expect(t.fullMarkdown(now: 15).contains("labeled Room"))
        t.setVoices([Key(speaker: "Me", start: 1): "Me", Key(speaker: "Me", start: 5): "Speaker 1", Key(speaker: "Me", start: 9): "Me"], on: ["Me"])
        let md = t.fullMarkdown(now: 15)
        #expect(md.contains("**[0:01] Me:** Let's start with the budget."))
        #expect(md.contains("**[0:05] Speaker 1:** I have the numbers here."))
        #expect(md.contains("**[0:09] Me:** Great, go ahead."))
        #expect(md.contains("No computer audio, so everyone is on your mic: Me, Speaker 1.") && !md.contains("labeled Room"))
        // A saved part can be written again with the names in it.
        #expect(t.part(1)?.markdown.contains("Speaker 1:") == true)
        #expect(t.part(2) == nil)
        // A later pass that no longer names a line takes its name away.
        t.setVoices([:], on: ["Me"])
        #expect(t.fullMarkdown(now: 15).contains("labeled Room"))
    }

    @Test func aCallWithSeveralPeopleSaysWhoIsWhere() {
        typealias Key = MeetingTranscript.LineKey
        var t = MeetingTranscript(startedAt: Date(timeIntervalSince1970: 0))
        t.add(.init(speaker: MeetingTranscript.them, start: 1, end: 4, text: "Thanks for joining, everyone."))
        t.add(.init(speaker: MeetingTranscript.me, start: 5, end: 8, text: "Happy to be here."))
        t.add(.init(speaker: MeetingTranscript.them, start: 9, end: 12, text: "Shall we start with pricing?"))
        t.add(.init(speaker: MeetingTranscript.me, start: 13, end: 16, text: "I can take notes."))
        // A plain one-to-one call needs no note at all.
        t.setVoices([Key(speaker: "Them", start: 1): "Them", Key(speaker: "Them", start: 9): "Them",
                     Key(speaker: "Me", start: 5): "Me", Key(speaker: "Me", start: 13): "Me"], on: ["Me", "Them"])
        #expect(!t.fullMarkdown(now: 20).contains("told apart"))
        // Two people on the call, and a colleague next to me.
        t.setVoices([Key(speaker: "Them", start: 1): "Speaker 1", Key(speaker: "Them", start: 9): "Speaker 2",
                     Key(speaker: "Me", start: 5): "Me", Key(speaker: "Me", start: 13): "Speaker 3"], on: ["Me", "Them"])
        let md = t.fullMarkdown(now: 20)
        #expect(md.contains("On your mic: Me, Speaker 3. On the computer's audio: Speaker 1, Speaker 2."))
        #expect(md.contains("**[0:01] Speaker 1:** Thanks for joining, everyone."))
        #expect(md.contains("**[0:13] Speaker 3:** I can take notes."))
    }

    @Test func aLineGetsAVoiceOnlyWhenOneWasHeardForMostOfIt() {
        let turns: [(voice: String, start: TimeInterval, end: TimeInterval)] = [("A", 0, 10), ("B", 10, 20), ("A", 30, 40)]
        let got = VoiceLabels.assign(lines: [(1, 9), (8, 16), (21, 21.5), (19, 23), (25, 26)], turns: turns)
        // Third: nobody during it, even though B stopped a second earlier. Fourth: B for a quarter of it.
        #expect(got == ["A", "B", nil, nil, nil])
    }

    @Test func everyKindOfMeetingIsNamedOneWay() {
        typealias V = VoiceLabels.Voice
        let mine: [Float] = [1, 0, 0, 0], a: [Float] = [0, 1, 0, 0], b: [Float] = [0, 0, 1, 0], c: [Float] = [0, 0, 0, 1]
        let likeMe = VoiceLabels.unit([0.9, 0.1, 0, 0])
        // In person, three people on one mic.
        var names = VoiceLabels.names(voices: [V(id: "m1", print: a, onMic: true), V(id: "m2", print: likeMe, onMic: true), V(id: "m3", print: b, onMic: true)], mine: mine)
        #expect(names == ["m1": "Speaker 1", "m2": "Me", "m3": "Speaker 2"])
        // Two mic voices that both sound like the user: nobody is called Me.
        names = VoiceLabels.names(voices: [V(id: "m1", print: likeMe, onMic: true), V(id: "m2", print: VoiceLabels.unit([0.85, 0.2, 0, 0]), onMic: true)], mine: mine)
        #expect(names == ["m1": "Speaker 1", "m2": "Speaker 2"])
        // A one-to-one call, and no fingerprint for the user: plain Me and Them.
        names = VoiceLabels.names(voices: [V(id: "c1", print: a, onMic: false), V(id: "m1", print: b, onMic: true)], mine: nil)
        #expect(names == ["c1": "Them", "m1": "Me"])
        // A call with three remote people; the user alone at the desk. Me is never looked for on the call.
        names = VoiceLabels.names(voices: [V(id: "c1", print: a, onMic: false), V(id: "m1", print: likeMe, onMic: true),
                                           V(id: "c2", print: likeMe, onMic: false), V(id: "c3", print: c, onMic: false)], mine: mine)
        #expect(names == ["c1": "Speaker 1", "m1": "Me", "c2": "Speaker 2", "c3": "Speaker 3"])
        // The mic also picks up a remote voice through the speakers: one person, one name.
        names = VoiceLabels.names(voices: [V(id: "c1", print: a, onMic: false), V(id: "c2", print: b, onMic: false),
                                           V(id: "m1", print: likeMe, onMic: true), V(id: "m2", print: VoiceLabels.unit([0, 0.1, 0.95, 0]), onMic: true)], mine: mine)
        #expect(names == ["c1": "Speaker 1", "c2": "Speaker 2", "m1": "Me", "m2": "Speaker 2"])
        // At the next snapshot the voices come back in another order, plus a newcomer; numbers hold.
        names = VoiceLabels.names(voices: [V(id: "x", print: b, onMic: false), V(id: "y", print: c, onMic: false), V(id: "z", print: a, onMic: false)],
                                  mine: mine, previous: ["Speaker 1": a, "Speaker 2": b, "Me": mine])
        #expect(names == ["x": "Speaker 2", "y": "Speaker 3", "z": "Speaker 1"])
    }
}
