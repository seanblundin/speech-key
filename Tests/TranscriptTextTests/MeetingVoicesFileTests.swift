import Foundation
import Testing
@testable import TranscriptText

struct MeetingVoicesFileTests {
    let file = """
    # Meeting 2026-11-26 14:00 · x7bm3z

    Length 12:00 · 1 part saved

    _Voices are told apart by sound; the numbers follow the order people first spoke. On your mic: Me, Speaker 2. On the computer's audio: Speaker 1. A name can be wrong, most often on short lines and when people talk over each other._

    **[0:01] Speaker 1:** Thanks for joining. I want to talk about the launch date and whether Speaker 2 agrees we can cut scope.

    **[0:20] Me:** Happy to. I think Friday is realistic if we drop the pricing page.

    **[0:41] Speaker 2:** I'd rather not drop it. The pricing page is the whole reason people sign up in the first place.

    **[5:10] Speaker 1:** Okay. Then let's move the date instead and keep everything in. Does a week later work for both of you?

    **[11:30] Speaker 2:** Yes.

    """

    @Test func theVoicesThatCanBeNamedAreFound() {
        #expect(MeetingVoicesFile.voices(file) == ["Speaker 1", "Speaker 2"])     // Me is already known
        let p = MeetingVoicesFile.paragraphs(file)
        #expect(p.count == 5 && p[3].seconds == 310 && p[3].voice == "Speaker 1")
        #expect(MeetingVoicesFile.words(of: "Speaker 2", in: p) == 20)
        #expect(MeetingVoicesFile.voices("**[0:01] Room:** Everyone at once.\n\n**[0:05] Them:** Hello there.\n") == ["Them"])
    }

    @Test func aNameReplacesTheLabelAndNothingPeopleSaid() {
        let named = MeetingVoicesFile.renaming(file, from: "Speaker 2", to: "Priya Shah")
        #expect(named.contains("**[0:41] Priya Shah:** I'd rather not drop it."))
        #expect(named.contains("**[11:30] Priya Shah:** Yes."))
        #expect(named.contains("On your mic: Me, Priya Shah. On the computer's audio: Speaker 1."))
        // Someone saying "Speaker 2" out loud stays as they said it, and other voices are untouched.
        #expect(named.contains("whether Speaker 2 agrees we can cut scope."))
        #expect(named.contains("**[0:01] Speaker 1:**"))
        // And it can be changed again, or put back.
        #expect(MeetingVoicesFile.renaming(named, from: "Priya Shah", to: "Speaker 2") == file)
        // "Speaker 1" must not catch "Speaker 12".
        let twelve = "**[0:01] Speaker 12:** Hello there everyone.\n"
        #expect(MeetingVoicesFile.renaming(twelve, from: "Speaker 1", to: "Ana") == twelve)
    }

    @Test func namesAreMadeSafeToUseAsLabels() {
        #expect(MeetingVoicesFile.usableName("  Priya   Shah ") == "Priya Shah")
        #expect(MeetingVoicesFile.usableName("Dr. Okafor: lead") == "Dr. Okafor lead")
        #expect(MeetingVoicesFile.usableName("Me") == nil && MeetingVoicesFile.usableName("   ") == nil)
    }

    @Test func quotesAreWholeSentencesFromAcrossTheMeeting() {
        let p = MeetingVoicesFile.paragraphs(file)
        let one = MeetingVoicesFile.quotes(of: "Speaker 1", in: p)
        #expect(one.first?.text == "I want to talk about the launch date and whether Speaker 2 agrees we can cut scope.")
        #expect(one.contains { $0.clock == "5:10" })
        #expect(!one.contains { $0.text == "Okay." })                         // too short to recognize anyone by
        // Someone who barely spoke still shows what they said.
        #expect(!MeetingVoicesFile.quotes(of: "Speaker 2", in: p).isEmpty)
    }

    /// What the on-device model really wrote for four voices (2026-11-26).
    @Test func theNoteAboutAVoiceReadsTheSameWayEveryTime() {
        #expect(MeetingVoicesFile.tidyNote("The person discussed the design of the product, its features, and its target audience.")
                == "Discussed the design of the product, its features, and its target audience.")
        #expect(MeetingVoicesFile.tidyNote("They raised the topic of the crocodile drawing and wanted to change it to a pelican.")
                == "Raised the topic of the crocodile drawing and wanted to change it to a pelican.")
        #expect(MeetingVoicesFile.tidyNote("The person discussed the design, functionality, and user-friendliness of the remote control, emphasizing the need for a product that is accessible to a wide range of users, including older generations.")
                == "Discussed the design, functionality, and user-friendliness of the remote control.")
        #expect(MeetingVoicesFile.tidyNote("**Wanted a later date.** It also matters that…") == "Wanted a later date.")
        #expect(MeetingVoicesFile.tidyNote("Okay.") == nil)
    }
}
