import Foundation
import Testing
@testable import TranscriptText

struct CleanVerbatimTests {
    func check(_ input: String, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(CleanVerbatim.apply(input) == expected, sourceLocation: sourceLocation)
    }

    @Test func testFillersGo() {
        check("Um, so the demo is Friday.", "So the demo is Friday.")
        check("We should, uh, ship it.", "We should ship it.")
        check("And then, um.", "And then.")
        check("I think uh we can do it", "I think we can do it")
    }

    @Test func testPhraseRestartCollapses() {
        check("Um, so the zentro demo, uh, the zentro demo is on Friday.", "So the zentro demo is on Friday.")
        check("I think, I think it's good.", "I think it's good.")
    }

    @Test func testFileExtensionsKeepTheirDot() {
        check("Put it in a .md that I can send to Rosa.", "Put it in a .md that I can send to Rosa.")
        check("Write the notes to readme.md and send them over.", "Write the notes to readme.md and send them over.")
        check("It works. now ship it", "It works. Now ship it")
        check("Done .", "Done.")
    }

    @Test func testSmallWordStutterCollapses() {
        check("the the plan", "The plan")
        check("I, I don't know.", "I don't know.")
        check("Send it to to Justin.", "Send it to Justin.")
    }

    @Test func testMeaningfulRepeatsStay() {
        check("I know that that is true.", "I know that that is true.")
        check("It was very, very good.", "It was very, very good.")
        check("No, no, no.", "No, no, no.")
        // A repeated sentence is emphasis (rules.md), not a stutter.
        check("I think it's good. I think it's good.", "I think it's good. I think it's good.")
    }

    @Test func testLikeFiller() {
        check("And, like, Elijah wants the numbers.", "And Elijah wants the numbers.")
        check("Like, I think we should go.", "I think we should go.")
        // Real uses of "like" stay.
        check("I like it.", "I like it.")
        check("It costs like five dollars.", "It costs like five dollars.")
        check("She was like, no way.", "She was like, no way.")
    }

    @Test func testConversationalPhrasesStay() {
        check("You know, I mean, it's fine.", "You know, I mean, it's fine.")
        check("So okay, scratch that, use the other one.", "So okay, scratch that, use the other one.")
    }

    @Test func testNoOpOnCleanText() {
        let s = "Hey Justin, can you ask Tighe whether the NOVA listing went live?"
        check(s, s)
        check("", "")
    }

    @Test func testChunkSeams() {
        #expect(ChunkJoiner.join(["results for the white paper.", "paper test, and I want them"]) == "results for the white paper test, and I want them")
        #expect(ChunkJoiner.join(["I think it's done.", "Next, the budget."]) == "I think it's done. Next, the budget.")
        #expect(ChunkJoiner.join(["one", "", "two"]) == "one two")
        #expect(ChunkJoiner.join(["only the two eyes", "Then the second thing"]) == "only the two eyes. Then the second thing")
        #expect(ChunkJoiner.join(["ask", "Justin about it"]) == "ask Justin about it")
    }
}
