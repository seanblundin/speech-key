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
        var t = MeetingTranscript(startedAt: Date(timeIntervalSince1970: 0))
        t.add(.init(speaker: MeetingTranscript.me, start: 1, end: 4, text: "Let's start with the budget."))
        t.add(.init(speaker: MeetingTranscript.me, start: 5, end: 8, text: "I have the numbers here."))
        t.add(.init(speaker: MeetingTranscript.me, start: 9, end: 12, text: "Great, go ahead."))
        _ = t.makePart(endingAt: 15)
        #expect(t.fullMarkdown(now: 15).contains("labeled Room"))
        t.setVoices([1: "Me", 5: "Speaker 1", 9: "Me"])
        let md = t.fullMarkdown(now: 15)
        #expect(md.contains("**[0:01] Me:** Let's start with the budget."))
        #expect(md.contains("**[0:05] Speaker 1:** I have the numbers here."))
        #expect(md.contains("**[0:09] Me:** Great, go ahead."))
        #expect(md.contains("told apart by sound") && !md.contains("labeled Room"))
        // A saved part can be written again with the names in it.
        #expect(t.part(1)?.markdown.contains("Speaker 1:") == true)
        #expect(t.part(2) == nil)
    }

    @Test func linesGoToTheVoiceThatOverlapsMost() {
        let turns: [(voice: String, start: TimeInterval, end: TimeInterval)] = [("A", 0, 10), ("B", 10, 20), ("A", 30, 40)]
        let got = VoiceLabels.assign(lines: [(1, 9), (8, 16), (21, 21.5), (25, 26)], turns: turns)
        #expect(got == ["A", "B", "B", nil])     // third: nobody during it, B ended a second before; fourth: too far from anyone
    }

    @Test func meIsOnlyAClearMatchAndNumbersStaySteady() {
        let mine: [Float] = [1, 0, 0], other: [Float] = [0, 1, 0], third: [Float] = [0, 0, 1]
        let prints = ["S1": other, "S2": VoiceLabels.unit([0.9, 0.1, 0]), "S3": third]
        var names = VoiceLabels.names(order: ["S1", "S2", "S3"], prints: prints, mine: mine)
        #expect(names == ["S1": "Speaker 1", "S2": "Me", "S3": "Speaker 2"])
        // Two voices that both sound like the user: nobody is called Me.
        names = VoiceLabels.names(order: ["S1", "S2"], prints: ["S1": VoiceLabels.unit([0.9, 0.1, 0]), "S2": VoiceLabels.unit([0.85, 0.2, 0])], mine: mine)
        #expect(names == ["S1": "Speaker 1", "S2": "Speaker 2"])
        // No fingerprint for the user: everyone is numbered.
        #expect(VoiceLabels.names(order: ["S1"], prints: prints, mine: nil) == ["S1": "Speaker 1"])
        // At the next snapshot the voices come back in another order; each keeps its name.
        let before = ["Speaker 1": other, "Speaker 2": third, "Me": mine]
        names = VoiceLabels.names(order: ["X", "Y", "Z", "W"], prints: ["X": third, "Y": mine, "Z": other, "W": VoiceLabels.unit([1, 1, 1])],
                                  mine: mine, previous: before)
        #expect(names == ["X": "Speaker 2", "Y": "Me", "Z": "Speaker 1", "W": "Speaker 3"])
    }
}
