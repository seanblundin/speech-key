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

    // The three below come from Sean's own dictation history (2026-11-18): each rule was replayed
    // over 588 real dictations and every cut read by hand.

    @Test func cutOffWordStartsGo() {
        check("And then the only w white paper that was written.", "And then the only white paper that was written.")
        check("So s within the shared folder there's just dated packets.", "So within the shared folder there's just dated packets.")
        check("Yeah, I mean sh really quickly show me the split.", "Yeah, I mean really quickly show me the split.")
        check("Do you s foresee these tools working?", "Do you foresee these tools working?")
        check("Back to like the r the overall risk plan.", "Back to like the overall risk plan.")
        check("Then we will tr we'll pick the winner.", "Then we will we'll pick the winner.")
    }

    @Test func loneLettersThatMeanSomethingStay() {
        for keep in [
            "Let's go with plan b for now.",
            "Press s to save and hold shift f to search.",
            "Put it in column d of the sheet.",
            "It takes about 60 s every time.",
            "My friend spells it j i m m y.",
            "We sell b to b software.",
            "Wear the t shirt and check the p value.",
            "Ana de la Cruz said to give em a call.",
            "The x axis is time and the y axis is cost.",
            "Do you want a or b for lunch?",
            "Send it to youtube.com and gmail.com by 11.59 p.m. tonight.",
        ] { check(keep, keep) }
    }

    @Test func onlySmallConnectingWordsCollapseWhenDoubled() {
        check("It should use as as a column.", "It should use as a column.")
        check("Hovering over things should should work.", "Hovering over things should work.")
        check("Keep it in your your mind.", "Keep it in your mind.")
        check("Well, let's let's go with the second one.", "Well, let's go with the second one.")
        // Nouns, adjectives and verbs are doubled on purpose often enough that they always stay.
        for keep in [
            "Create a master master folder anyway.", "Okay, final final take.", "You wanted to generate generate the image.",
            "That is very very important.", "No no, not that one.", "I think that that is fine.",
            "Blah blah blah, you get it.", "Wait, wait, hold on.", "It was one one two three.",
            "It's not not working.", "Really really good.", "He had had enough.",
        ] { check(keep, keep) }
    }

    @Test func recognizerMarksBecomeAmpersandsOrGo() {
        check("Then we move to the Q<unk>A timer.", "Then we move to the Q&A timer.")
        check("It was <unk> a long day.", "It was a long day.")
    }

    @Test func everyCutIsRecordedWithItsKind() {
        let r = CleanVerbatim.applyNoting("Um, so s within the the Q<unk>A folder we should should make it.")
        #expect(r.text == "So within the Q&A folder we should make it.")
        #expect(r.edits.map(\.kind) == [.glitch, .filler, .fragment, .repeat, .repeat])
        #expect(r.edits.first { $0.kind == .fragment }?.cut == "s")
        #expect(CleanVerbatim.applyNoting("Nothing to fix here.").edits.isEmpty)
    }
}
