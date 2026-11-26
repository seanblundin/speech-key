import Foundation
import Testing
@testable import TranscriptText

struct SpelledNamesTests {
    @Test func aNameThenItsSpellingIsLearned() {
        #expect(SpelledNames.lessons(in: "Then a page that says slash Sara S-A-R-A-H uh and then connect it to a form.")
                == [.init(heard: "Sara", write: "Sarah")])
        #expect(SpelledNames.lessons(in: "I met Jamie, J-I-M-M-Y, at the event and he wants a demo.")
                == [.init(heard: "Jamie", write: "Jimmy")])
        // The spelling can come later in the sentence, with or without dashes (Sean's test, 2026-11-26).
        #expect(SpelledNames.lessons(in: "My friend Anemonee is a good friend of mine, A-N-I-E-M-O-N-E.")
                == [.init(heard: "Anemonee", write: "Aniemone")])
        #expect(SpelledNames.lessons(in: "My friend Anemonee is a good friend of mine, A N I E M O N E.")
                == [.init(heard: "Anemonee", write: "Aniemone")])
        #expect(SpelledNames.lessons(in: "It's spelled A-N-I-E-M-O-N-E, and Anemonee's team starts Monday.")
                == [.init(heard: "Anemonee", write: "Aniemone")])
        #expect(SpelledNames.lessons(in: "Ask Aidan, that's A I D E N, about the lease.")
                == [.init(heard: "Aidan", write: "Aiden")])
    }

    /// Sean's real dictations where the spelled word is sometimes the wrong one. Left for Claude or the agent.
    @Test func sentencesAboutAMistakeAreLeftAlone() {
        for text in [
            "Hey, it seems like you always mistranscribe like Jimmy, like my friend J-I-M-M-Y, as Jamie, J-A-M-M-Y. Can you add that to the glossary?",
            "Uh, your last transcription did K A Y instead of K-A-I.",
            "My friend Devon is frequently mistranscribed as D E V I N.",
            "Send the deck to Kalshi, that's K-A-L-S-H-I, not Kelsey.",
            "You did console like C-O-N-S-O-L-E, but it should be consul like C-O-N-S-U-L.",
        ] { #expect(SpelledNames.lessons(in: text).isEmpty, "\(text)") }
    }

    @Test func nothingIsLearnedWithoutAMisheardName() {
        for text in [
            "Send it to Sarah S-A-R-A-H today.",                 // already right
            "My friend Anemone, A N E M O N E, is a good friend of mine.",   // already right
            "So I I I want to be able to put a name in the CRM.",       // a stutter
            "Make the header say sale S-A-L-E in big letters.",         // an everyday word
            "Talk to the T-H-E-O team about it.",                       // "the" is not a misheard Theo
            "The T-H-E-O team is ready.",
            "The acronym is A-S-A-P and it goes under the title.",
            "Put the letters Q-B-R on the cover.",
        ] { #expect(SpelledNames.lessons(in: text).isEmpty, "\(text)") }
    }

    @Test func theLessonIsWrittenIntoTheText() {
        let lesson = SpelledNames.Lesson(heard: "Sara", write: "Sarah")
        #expect(SpelledNames.apply(lesson, to: "Slash Sara S-A-R-A-H, and tell Sara's team. Saratoga stays.")
                == "Slash Sarah S-A-R-A-H, and tell Sarah's team. Saratoga stays.")
    }

    @Test func rawViewMarksWhatTheCleanupCut() {
        let raw = "Um, so s within the the Q<unk>A folder we should should make it."
        let cleaned = CleanVerbatim.apply(raw)
        let cut = RawDiff.onlyInRaw(raw: raw, cleaned: cleaned).map { (raw as NSString).substring(with: $0) }
        #expect(cut.count == 5 && cut.contains("Um,") && cut.contains("s") && cut.contains("Q<unk>A"))
        #expect(RawDiff.differs(raw: raw, cleaned: cleaned))
        #expect(!RawDiff.differs(raw: "it works. now ship it", cleaned: "It works. Now ship it "))
    }
}
