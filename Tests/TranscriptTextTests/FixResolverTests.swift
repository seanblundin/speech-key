import Foundation
import Testing
@testable import TranscriptText

struct FixResolverTests {
    let empty = Glossary(markdown: "| Heard as | Write as | Notes |\n|---|---|---|\n")
    func decide(_ correct: String, _ wrong: [String], said: String, latest: [String], spelled: [String] = [],
                glossary: Glossary? = nil) -> FixResolver.Decision {
        FixResolver.decide(correct: correct, wrong: wrong, spelled: spelled, said: said, latest: latest,
                           written: { w in latest.contains { FixResolver.contains($0, w) } }, glossary: glossary ?? empty)
    }

    /// Sean, 2026-11-26: the model invented "Marisol Tuny"; the miss was in the dictation before.
    @Test func theWrongWordIsFoundInTheLastDictations() {
        let said = "Yo, the last thing I did, did you catch that? Like, it needs to be Marisol Tunney. Is that fixed now?"
        #expect(decide("Marisol Tunney", ["Marisol Tuny"], said: said, latest: ["Marigold Tenny", "Send the notes to the team."])
                == .add(heard: ["Marigold Tenny"], correct: "Marisol Tunney"))
        // What really happened: he had already fixed it by hand, and dictated it again correctly.
        let fixed = Glossary(markdown: "| Heard as | Write as | Notes |\n|---|---|---|\n| Marigold Tenny | Marisol Tunney |  |\n")
        #expect(decide("Marisol Tunney", ["Marisol Tuny"], said: said, latest: ["Marisol Tunney", "Marigold Tenny"], glossary: fixed)
                == .alreadyFixed(heard: "Marigold Tenny", correct: "Marisol Tunney"))
    }

    /// What the model returns once it is shown the latest dictations: the real miss plus a stray
    /// sentence. And two older real commands where it handed back whatever words were nearby.
    @Test func onlyWordsThatSoundLikeTheRightOneCount() {
        let fixed = Glossary(markdown: "| Heard as | Write as | Notes |\n|---|---|---|\n| Marigold Tenny | Marisol Tunney |  |\n")
        #expect(decide("Marisol Tunney", ["Marigold Tenny", "Like well if I'm right here."],
                       said: "The last thing I did, it needs to be Marisol Tunney. Is that fixed now?",
                       latest: ["Marisol Tunney", "Marigold Tenny", "Like well if I'm right here."], glossary: fixed)
                == .alreadyFixed(heard: "Marigold Tenny", correct: "Marisol Tunney"))
        // A name spelled with stops and starts, and the real miss sitting in the dictation before.
        #expect(decide("DE-VON-Space MACEDA", ["Then", "hey", "you"], said: "Then you say, hey, you just transcribed that name wrong. It's DE-VON [spelled]-Space MACEDA [spelled].",
                       latest: ["Hey, so it's listening to you and Devan maseda."], spelled: ["DEVON", "MACEDA"])
                == .add(heard: ["Devan maseda"], correct: "Devon Maceda"))
        #expect(decide("Devon", ["Devin", "Devon Devon"], said: "Devin is frequently a mistranscription of Devon Devon.",
                       latest: ["I sent the email this morning."]) == .add(heard: ["Devin"], correct: "Devon"))
        // The wrong word is only in the command itself, which is fine: the user said it.
        #expect(decide("Leo", ["lion"], said: "I wanna say Leo, but it always transcribes it as like lion.",
                       latest: ["I'm transcribing text right now."]) == .add(heard: ["lion"], correct: "Leo"))
    }

    @Test func aWrongWordTheUserNamedStillWins() {
        #expect(decide("Jimmy", ["Jammy"], said: "Jammy should be Jimmy", latest: ["Tell Jammy I said hi.", "Jamie called."])
                == .add(heard: ["Jammy"], correct: "Jimmy"))
    }

    @Test func nothingIsInventedWhenNothingFits() {
        // The newest dictation already has it right and nothing else comes close.
        #expect(decide("Marisol Tunney", [], said: "It needs to be Marisol Tunney", latest: ["Marisol Tunney", "What time is the call?"])
                == .alreadyRight("Marisol Tunney"))
        // A question the model mistook for a fix: no recent word is anything like it.
        #expect(decide("self-aware", ["yes", "pill"], said: "Are you self-aware? Respond with a yes in the pill.",
                       latest: ["What is the order of things that need to happen right now?"]) == .unknown("self-aware"))
        // Everyday words are only a miss when they are nearly the same sound.
        #expect(FixResolver.nearest(to: "Devon", in: ["So now what is next for the seven in the room?"]) == nil)
        #expect(FixResolver.nearest(to: "Lyon", in: ["I told lion about it."]) == "lion")     // close enough in sound to be a miss
        #expect(FixResolver.nearest(to: "Lyon", in: ["I told them about it."]) == nil)
        #expect(FixResolver.nearest(to: "Devon", in: ["I asked Devin about it."]) == "Devin")
    }
}
