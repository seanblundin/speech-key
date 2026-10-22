import Foundation
import Testing
@testable import TranscriptText

struct GlossaryDocumentTests {
    static let legacy = """
    *Last edited: 2026-10-21*

    Goal: names that get mangled.

    Format: "Heard as" is what the transcript shows.

    ## People

    | Heard as | Correct |
    |---|---|
    | Teeg, Tig | Tighe (Rory Tighe, leads the design studio) |
    | Dylan, Dana (when Daniel is in the room) | Daniel |

    Correct as usually transcribed: Justin Marlowe, Ilan (an investor). The cousins are Rosa, Daniel and Jack.

    ## Book club (Thursday group)

    | Heard as | Correct |
    |---|---|
    | Zephy | Zeffy (the payment app members use for dues) |
    | Read-a-thon | correct as written: the fall fundraiser |

    ## Spoken symbols and conventions

    - Spoken "dot" in a filename is a literal `.`.

    ## Added from Speech Key

    Rows Sean added from Speech Key. Move them into the right table when convenient.

    | Heard as | Correct |
    |---|---|
    | Neve | Niamh |

    ## Unresolved

    | Heard as | Best guess | Context |
    |---|---|---|
    | Dworkin | Dariush | Tuesday meeting |
    | Azura | a person, spelling unconfirmed | work context |
    """

    @Test func convertsTheOlderLayout() {
        let doc = GlossaryDocument(markdown: Self.legacy)
        #expect(doc.wasConverted)
        let byWrite = Dictionary(doc.rows.map { ($0.write, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byWrite["Tighe"]?.heard == "Teeg, Tig")
        #expect(byWrite["Tighe"]?.notes == "Rory Tighe, leads the design studio")
        #expect(byWrite["Daniel"]?.heard == "Dylan, Dana")
        #expect(byWrite["Daniel"]?.notes == "when Daniel is in the room")
        #expect(byWrite["Zeffy"]?.notes == "Book club · the payment app members use for dues")
        #expect(byWrite["Read-a-thon"]?.notes == "Book club · the fall fundraiser")
        #expect(byWrite["Justin Marlowe"]?.heard == "")
        #expect(byWrite["Ilan"]?.notes.contains("an investor") == true)
        #expect(byWrite["Niamh"]?.heard == "Neve")
        #expect(byWrite["Dariush"]?.notes.hasPrefix("unconfirmed") == true)
        #expect(byWrite["Azura"]?.notes.hasPrefix("unconfirmed") == true)
        // Prose survives below the table; the "added from" intro doesn't.
        #expect(doc.postamble.contains("## Spoken symbols and conventions"))
        #expect(doc.postamble.contains("The cousins are Rosa, Daniel and Jack."))
        #expect(!doc.postamble.contains("Move them into the right table"))
        #expect(doc.preamble.contains("Goal: names that get mangled."))
        #expect(doc.markdown.contains(GlossaryDocument.header))
    }

    @Test func roundTripsTheOneTableLayout() {
        let once = GlossaryDocument(markdown: Self.legacy).markdown
        let twice = GlossaryDocument(markdown: once)
        #expect(!twice.wasConverted)
        #expect(twice.markdown == once)
    }

    @Test func behavesTheSameAfterConverting() {
        let before = Glossary(markdown: Self.legacy)
        let after = Glossary(markdown: GlossaryDocument(markdown: Self.legacy).markdown)
        for s in ["Ask Teeg about it", "Pay with Zephy", "Neve said hi", "Dylan is here", "Dworkin wrote that"] {
            #expect(after.apply(s) == before.apply(s), "\(s)")
        }
        #expect(Set(after.hints).isSuperset(of: ["Tighe", "Justin Marlowe", "Ilan"]))
    }

    @Test func addingMovesHeardFormsAndMerges() {
        var doc = GlossaryDocument(markdown: Self.legacy)
        doc.add(heard: ["Tig"], write: "Tig Jr")
        #expect(doc.rows.first { $0.write == "Tighe" }?.heard == "Teeg")
        doc.add(heard: ["Niev"], write: "Niamh")
        #expect(doc.rows.first { $0.write == "Niamh" }?.heard == "Neve, Niev")
        let removed = doc.remove(["Niev"])
        #expect(removed.count == 1)
        #expect(doc.rows.first { $0.write == "Niamh" }?.heard == "Neve")
        doc.remove(["Niamh"])
        #expect(!doc.rows.contains { $0.write == "Niamh" })
    }

    @Test func notesDecideHowARowIsUsed() {
        let md = """
        | Heard as | Write as | Notes |
        |---|---|---|
        | Teegh | Tighe | leads the design studio |
        | Eli | Elias Moreno | only in book club talk |
        | Eli | Elijah | only in work context |
        | Dworkin | Dariush | unconfirmed · Tuesday meeting |
        |  | Justin Marlowe | listen for it |
        """
        let g = Glossary(markdown: md)
        #expect(g.apply("Ask Teegh") == "Ask Tighe")
        #expect(g.apply("Eli paid dues") == "Eli paid dues")
        #expect(g.apply("Dworkin wrote it") == "Dworkin wrote it")
        #expect(g.hints.contains("Justin Marlowe"))
        #expect(!g.hints.contains("Dariush"))
        let candidates = g.conditionalCandidates(in: "Did Eli pay his dues?")
        #expect(candidates.count == 1)
        #expect(Set(candidates.first?.options.map(\.target) ?? []) == ["Elias Moreno", "Elijah"])
        let fixed = Glossary.applying([(word: "Eli", target: "Elias Moreno")], to: "Did Eli pay? Eli said yes.")
        #expect(fixed.text == "Did Elias Moreno pay? Elias Moreno said yes.")
    }
}
