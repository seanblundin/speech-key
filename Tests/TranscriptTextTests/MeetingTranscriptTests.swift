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
        #expect(md.contains("**[0:00] Me:** one\n"))
        #expect(md.contains("**[0:10] Me:** two w0"))
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
}
