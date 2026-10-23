import Foundation
import Testing
@testable import TranscriptText

struct MeetingNamesTests {
    @Test func codesAreSixUnambiguousCharacters() {
        for _ in 0..<200 {
            let c = MeetingNames.newCode()
            #expect(c.count == 6)
            #expect(c.allSatisfy { MeetingNames.alphabet.contains($0) })
            #expect(!c.contains("0") && !c.contains("o") && !c.contains("1") && !c.contains("l"))
        }
    }

    @Test func folderNamesCarryDateTimeAndCode() {
        let d = DateComponents(calendar: .init(identifier: .gregorian), year: 2026, month: 10, day: 22, hour: 15, minute: 47).date!
        let name = MeetingNames.folder(started: d, code: "x7bm3z")
        #expect(name == "2026-10-22_1547_x7bm3z")
        #expect(MeetingNames.code(ofFolder: name) == "x7bm3z")
        #expect(MeetingNames.code(ofFolder: "2026-10-22_1547") == nil)
        #expect(MeetingNames.code(ofFolder: "2026-10-22_1547_toolong1") == nil)
    }

    @Test func everyFileEndsWithTheMeeting() {
        let tag = "2026-10-22_1547_x7bm3z"
        #expect(MeetingNames.full(tag) == "full_2026-10-22_1547_x7bm3z.md")
        #expect(MeetingNames.latest(tag) == "latest_2026-10-22_1547_x7bm3z.md")
        #expect(MeetingNames.part(2, start: 740, end: 1625, tag: tag) == "part-02_12m20-27m05_2026-10-22_1547_x7bm3z.md")
        #expect(MeetingNames.isFull("full_2026-10-22_1547_x7bm3z.md") && MeetingNames.isFull("full.md"))
        #expect(!MeetingNames.isFull("forge-experiments-proposal.md"))
    }

    @Test func partEndsReadFromOldAndNewNames() {
        #expect(MeetingNames.partEnd("part-04_28m31-51m57.md") == 3117)
        #expect(MeetingNames.partEnd("part-04_28m31-51m57_2026-10-22_1547_x7bm3z.md") == 3117)
        #expect(MeetingNames.partEnd("part-12_72m28-75m44_2026-10-22_1733_k4p9xw.md") == 4544)
        #expect(MeetingNames.partEnd("notes.md") == nil)
    }

    @Test func olderFilesGetTheTagAndOthersAreLeftAlone() {
        let tag = "2026-10-20_1157_k4p9xw"
        #expect(MeetingNames.renamed("full.md", tag: tag) == "full_2026-10-20_1157_k4p9xw.md")
        #expect(MeetingNames.renamed("latest.md", tag: tag) == "latest_2026-10-20_1157_k4p9xw.md")
        #expect(MeetingNames.renamed("part-02_07m09-27m35.md", tag: tag) == "part-02_07m09-27m35_2026-10-20_1157_k4p9xw.md")
        #expect(MeetingNames.renamed("part-02_07m09-27m35_2026-10-20_1157_k4p9xw.md", tag: tag) == nil)
        #expect(MeetingNames.renamed("forge-experiments-proposal.html", tag: tag) == nil)
        #expect(MeetingNames.renamed(".done.jsonl", tag: tag) == nil)
    }

    @Test func headingsCarryTheCode() {
        var t = MeetingTranscript(startedAt: Date(timeIntervalSince1970: 0))
        t.tag = "1970-01-01_0000_x7bm3z"
        t.code = "x7bm3z"
        t.add(.init(speaker: "Me", start: 1, end: 2, text: "Hello."))
        let p = t.makePart(endingAt: 10)
        #expect(p.fileName == "part-01_00m00-00m10_1970-01-01_0000_x7bm3z.md")
        #expect(p.markdown.components(separatedBy: "\n")[0].hasSuffix("part 1 · x7bm3z"))
        #expect(t.fullMarkdown(now: 10).components(separatedBy: "\n")[0].hasSuffix(" · x7bm3z"))
    }
}
