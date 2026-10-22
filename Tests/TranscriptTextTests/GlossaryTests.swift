import Foundation
import Testing
@testable import TranscriptText

struct GlossaryTests {
    // An older-format glossary with every kind of row the parser handles.
    static let sample = """
    *Last edited: 2026-10-15*

    ## People

    | Heard as | Correct |
    |---|---|
    | Jack Wustin | Jack Bastien |
    | Teeg, Tig, Teegh | Tighe (Rory Tighe, leads the design studio) |
    | Dylan, Dana (when Daniel is in the room) | Daniel |
    | Bastian, Boston (as a surname, or in an email like "boston.d@") | Bastien |
    | Luke Sorentos | Luke Sorentino (a co-founder) |
    | Luc | Luke (Sorentino) |

    Correct as usually transcribed: Justin Marlowe, Daniel Bastien, Ilan (an investor). The three Bastiens are Rosa, Daniel, and Jack.

    ## Work

    | Heard as | Correct |
    |---|---|
    | Sublimn, Sublime, Noba, Lemon, Nova | NOVA (the team's AI hiring desk; written in capitals) |
    | Clock (as an AI assistant) | Claude |
    | GPT-0, GPT zero | GPTZero |
    | Renault (in a list of test groups) | random |
    | the S team | S-Team |
    | Beecon, Beakon | Beacon |
    | Zentra | Zentro |
    | Trailblazers | Trailblazers is the student founders club across town |

    ## Unresolved

    | Heard as | Best guess | Context |
    |---|---|---|
    | Merlin | a tool Mike uses | meeting |
    """

    let g = Glossary(markdown: GlossaryTests.sample)

    @Test func testPlainRowsReplace() {
        #expect(g.apply("Ask Teegh about it.") == "Ask Tighe about it.")
        #expect(g.apply("Teegh's team is late.") == "Tighe's team is late.")
        #expect(g.apply("Loop in Jack Wustin.") == "Loop in Jack Bastien.")
        #expect(g.apply("the GPT-0 numbers") == "the GPTZero numbers")
        #expect(g.apply("Tell Luke Sorentos.") == "Tell Luke Sorentino.")
    }

    @Test func testConditionalRowsDoNotReplace() {
        #expect(g.apply("Dylan said hi.") == "Dylan said hi.")
        #expect(g.apply("I flew to Boston.") == "I flew to Boston.")
        #expect(g.apply("Check the clock.") == "Check the clock.")
        #expect(g.apply("Renault makes cars.") == "Renault makes cars.")
    }

    @Test func testCommonWordsOnlyReplaceWhenCapitalizedMidSentence() {
        #expect(g.apply("I'd like a lemon.") == "I'd like a lemon.")
        #expect(g.apply("That view was sublime.") == "That view was sublime.")
        #expect(g.apply("Post it on Lemon today.") == "Post it on NOVA today.")
        #expect(g.apply("Check the Nova repo.") == "Check the NOVA repo.")
    }

    @Test func testRecasing() {
        #expect(g.apply("the nova repo") == "the NOVA repo")
        #expect(g.apply("the zentro demo") == "the Zentro demo")
        #expect(g.apply("message the S team") == "message the S-Team")
        // "beacon" is an ordinary word, so its lowercase use stays.
        #expect(g.apply("the old beacon") == "the old beacon")
    }

    @Test func testDoesNotTouchPossessiveS() {
        #expect(g.apply("Tighe's team") == "Tighe's team")
    }

    @Test func testSpokenConventions() {
        #expect(g.apply("open notes dot MD") == "open notes.md")
    }

    @Test func testTermsAndHints() {
        let canon = Set(g.hints)
        let expected: Set<String> = ["Jack Bastien", "Tighe", "Daniel", "Bastien", "Luke Sorentino", "NOVA", "Claude", "GPTZero", "S-Team", "Beacon", "Zentro", "Justin Marlowe", "Daniel Bastien", "Ilan", "Trailblazers"]
        #expect(expected.subtracting(canon).isEmpty, "missing: \(expected.subtracting(canon))")
        #expect(!canon.contains("random"))
        #expect(!canon.contains("Merlin"))
        let nova = g.terms.first { $0.canonical == "NOVA" }
        #expect(Set(nova?.aliases ?? []) == ["Sublimn", "Sublime", "Noba", "Lemon"])
        // Conditional rows give a hint but no aliases.
        #expect(g.terms.first { $0.canonical == "Daniel" }?.aliases == [])
    }

    @Test func testChangesAreReported() {
        let r = g.applyWithChanges("Ask Teegh about the nova repo.")
        #expect(r.text == "Ask Tighe about the NOVA repo.")
        #expect(Set(r.changes.map(\.to)) == ["Tighe", "NOVA"])
    }

}

struct GlossaryEditorTests {
    @Test func addsSectionBeforeUnresolvedAndParses() {
        let updated = GlossaryEditor.addingRow(heard: "Tieg", correct: "Tighe", to: GlossaryTests.sample)
        #expect(updated.contains("## Added from Speech Key"))
        let addedAt = updated.range(of: "## Added from Speech Key")!.lowerBound
        let unresolvedAt = updated.range(of: "## Unresolved")!.lowerBound
        #expect(addedAt < unresolvedAt)
        #expect(Glossary(markdown: updated).apply("Ask Tieg.") == "Ask Tighe.")
    }

    @Test func appendsToExistingSection() {
        let once = GlossaryEditor.addingRow(heard: "Tieg", correct: "Tighe", to: GlossaryTests.sample)
        let twice = GlossaryEditor.addingRow(heard: "Zephi", correct: "Zeffy", to: once)
        #expect(twice.components(separatedBy: "## Added from Speech Key").count == 2)
        let g = Glossary(markdown: twice)
        #expect(g.apply("Pay Zephi, ask Tieg.") == "Pay Zeffy, ask Tighe.")
    }

    @Test func bumpsDate() {
        let d = DateComponents(calendar: .init(identifier: .gregorian), year: 2030, month: 1, day: 2).date!
        let updated = GlossaryEditor.addingRow(heard: "a", correct: "B", to: GlossaryTests.sample, today: d)
        #expect(updated.hasPrefix("*Last edited: 2030-01-02*"))
    }
}

struct GlossaryEditingTests {
    static let sample = """
    *Last edited: 2026-10-15*

    | Heard as | Correct |
    |---|---|
    | Jammy, Jamie | Jimmy (a friend) |
    | Dylan, Dana (when Daniel is in the room) | Daniel |
    | Teeg, Tig, Teegh | Tighe (Rory Tighe) |

    ## Unresolved

    | Jammy | James |
    """

    @Test func removeByEitherSpelling() {
        let byCorrect = GlossaryEditor.removing(["Jimmy"], from: Self.sample)
        #expect(!byCorrect.markdown.contains("Jimmy"))
        #expect(byCorrect.removed == [.init(heard: ["Jammy", "Jamie"], correct: "Jimmy", wholeRow: true)])
        // The Unresolved section is never touched.
        #expect(byCorrect.markdown.contains("| Jammy | James |"))

        // The model sometimes swaps the two sides; the row is still found.
        let swapped = GlossaryEditor.removing(["Jammy", "Jimmy"], from: Self.sample)
        #expect(!swapped.markdown.contains("Jimmy"))
    }

    @Test func removeOneHeardFormKeepsTheRestAndTheCondition() {
        let r = GlossaryEditor.removing(["Tig"], from: Self.sample)
        #expect(r.markdown.contains("| Teeg, Teegh | Tighe (Rory Tighe) |"))
        #expect(r.removed.first?.wholeRow == false)

        let d = GlossaryEditor.removing(["Dana"], from: Self.sample)
        #expect(d.markdown.contains("| Dylan (when Daniel is in the room) | Daniel |"))
    }

    @Test func theOldSectionNameIsRenamedOnTheNextAdd() {
        let old = Self.sample.replacingOccurrences(of: "\n## Unresolved", with: "\n## Added from Utter\n\n| Heard as | Correct |\n|---|---|\n| lion | Leo |\n\n## Unresolved")
        #expect(GlossaryEditor.utterRows(in: old).map(\.correct) == ["Leo"])
        let added = GlossaryEditor.addingRow(heard: "Kelsey", correct: "Kalshi", to: old)
        #expect(added.contains("## Added from Speech Key"))
        #expect(!added.contains("## Added from Utter"))
        #expect(GlossaryEditor.utterRows(in: added).map(\.correct) == ["Leo", "Kalshi"])
    }

    @Test func nothingMatchingChangesNothing() {
        let r = GlossaryEditor.removing(["Zelda"], from: Self.sample)
        #expect(r.markdown == Self.sample)
        #expect(r.removed.isEmpty)
    }

    @Test func addingMovesAHeardFormOffItsOldRow() {
        // "Jamie should be James": Jamie leaves the Jimmy row, then gets its own.
        let moved = GlossaryEditor.removing(["Jamie"], from: Self.sample, keepingTarget: "James")
        let added = GlossaryEditor.addingRow(heard: "Jamie", correct: "James", to: moved.markdown)
        #expect(added.contains("| Jammy | Jimmy (a friend) |"))
        #expect(added.contains("| Jamie | James |"))
        #expect(GlossaryEditor.utterRows(in: added).map(\.correct) == ["James"])
        let g = Glossary(markdown: added)
        #expect(g.apply("Jamie and Jammy") == "James and Jimmy")
    }
}

struct CorrectionDiffTests {
    @Test func aSwappedWordIsAReplacement() {
        let r = CorrectionDiff.replacements(from: "I talked to Jammy about it.", to: "I talked to Jimmy about it.")
        #expect(r == [.init(heard: "Jammy", correct: "Jimmy")])
    }

    @Test func phrasesAndCase() {
        #expect(CorrectionDiff.replacements(from: "the S team met", to: "the S-Team met") == [.init(heard: "S team", correct: "S-Team")])
        #expect(CorrectionDiff.replacements(from: "check nova today", to: "check NOVA today") == [.init(heard: "nova", correct: "NOVA")])
    }

    @Test func insertionsDeletionsPunctuationAndRewritesAreNot() {
        #expect(CorrectionDiff.replacements(from: "send it now", to: "send it right now").isEmpty)
        #expect(CorrectionDiff.replacements(from: "send it right now", to: "send it now").isEmpty)
        #expect(CorrectionDiff.replacements(from: "send it now", to: "send it now!").isEmpty)
        #expect(CorrectionDiff.replacements(from: "one two three four five six", to: "a b c d e f").isEmpty)
    }

    @Test func twoSeparateFixes() {
        let r = CorrectionDiff.replacements(from: "Ask Teegh about Nova", to: "Ask Tighe about NOVA")
        #expect(r == [.init(heard: "Teegh", correct: "Tighe"), .init(heard: "Nova", correct: "NOVA")])
    }
}

struct SpelledLettersTests {
    @Test func joinsSpelledRuns() {
        let r = SpelledLetters.join("Jammy should be J I M M Y, my friend")
        #expect(r.text == "Jammy should be JIMMY [spelled], my friend")
        #expect(r.words == ["JIMMY"])
        #expect(SpelledLetters.join("it's B-E-A-C-O-N").words == ["BEACON"])
        #expect(SpelledLetters.join("I think a meeting").words.isEmpty)
    }
}

struct CommandWordsTests {
    @Test func spelledNamesAreTitlecasedUnlessSeanSaidCaps() {
        #expect(CommandWords.tidy(correct: "JIMMY", wrong: ["Jammy"], spelled: ["JIMMY"], said: "Jammy should be J I M M Y")
                == .ok(correct: "Jimmy", wrong: ["Jammy"]))
        #expect(CommandWords.tidy(correct: "NASA", wrong: ["Nasser"], spelled: ["NASA"], said: "it's N A S A, all caps")
                == .ok(correct: "NASA", wrong: ["Nasser"]))
    }

    @Test func theCorrectWordIsNeverAlsoWrong() {
        #expect(CommandWords.tidy(correct: "Tighe", wrong: ["Teegh", "Tighe", "teegh"], spelled: [], said: "")
                == .ok(correct: "Tighe", wrong: ["Teegh"]))
        #expect(CommandWords.tidy(correct: "Jammy", wrong: ["Jammy"], spelled: [], said: "Jammy should be Jammy") == .sameWord("Jammy"))
        #expect(CommandWords.tidy(correct: "Jimmy", wrong: ["Jammy", "JIMMY"], spelled: ["JIMMY"], said: "") == .ok(correct: "Jimmy", wrong: ["Jammy"]))
        #expect(CommandWords.tidy(correct: "NOVA", wrong: ["Nova"], spelled: [], said: "") == .ok(correct: "NOVA", wrong: ["Nova"]))
    }

    @Test func capsOnlyTermsGetTheirLowercaseForm() {
        #expect(CommandWords.tidy(correct: "NOVA", wrong: [], spelled: [], said: "add NOVA") == .ok(correct: "NOVA", wrong: ["nova"]))
        #expect(CommandWords.tidy(correct: "", wrong: ["x"], spelled: [], said: "") == .missing)
    }

    @Test func fileExtensionsAreOrdinary() {
        // Name boosting only swaps out words that aren't ordinary, so "md file" must count as ordinary.
        #expect(WordFacts.isOrdinary("md file"))
        #expect(WordFacts.isOrdinary(".md"))
        #expect(!WordFacts.isOrdinary("Shivonne"))
    }
}
