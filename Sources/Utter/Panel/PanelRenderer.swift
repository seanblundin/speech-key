import AppKit
import SwiftUI

/// Renders the panel's tabs with made-up sample content, light and dark, for design review:
/// `SpeechKey --render-pill <dir>` (the same run renders the pill).
@MainActor
enum PanelRenderer {
    static func renderAll(to dir: String) {
        let glossaryFile = NSTemporaryDirectory() + "speechkey-render-glossary.md"
        let sample = """
        *Last edited: 2026-10-21*

        Goal: names Speech Key gets wrong.

        | Heard as | Write as | Notes |
        |---|---|---|
        | Neve | Niamh |  |
        | Shivonne, Shivon | Siobhan | design lead at the studio |
        | Eli | Elias Moreno | only in book club talk |
        | cube cuddle | kubectl |  |
        | Pree a, Priyah | Priya | client, onboarding project |
        | Fig ma | Figma |  |
        | sequel light | SQLite |  |
        | Mao | Mau | Maya's dog |
        |  | Kubernetes | listen for it |
        | Ava Lynn | Avelyn | unconfirmed · new client? |
        """
        try? sample.write(toFile: glossaryFile, atomically: true, encoding: .utf8)

        let now = Date()
        let m1 = "/tmp/speechkey-render/2026-11-04_1400_x7bm3z", m2 = "/tmp/speechkey-render/2026-11-03_1000_k4p9xw"
        func event(_ t: TimeInterval, _ e: AppEvent) -> History.Item {
            History.Item(time: now.addingTimeInterval(t), kind: .event(e.kind), app: nil, text: "", fixes: [], reply: nil,
                         delivery: nil, event: e)
        }
        func dictation(_ t: TimeInterval, _ app: String, _ text: String, fixes: [String] = [], delivery: String? = nil) -> History.Item {
            History.Item(time: now.addingTimeInterval(t), kind: .dictation, app: app, text: text, fixes: fixes, reply: nil, delivery: delivery)
        }
        let items: [History.Item] = [
            dictation(-60, "Messages", "Niamh, can you review it today?", fixes: ["Neve → Niamh"]),
            dictation(-300, "Slack", "Ask Priya whether Niamh signed off on the kubectl change.",
                      fixes: ["Pree a → Priya", "Neve → Niamh", "cube cuddle → kubectl"]),
            event(-75, AppEvent(time: now.addingTimeInterval(-75), kind: .glossaryAdded, heard: "Neve", write: "Niamh", source: "voice")),
            History.Item(time: now.addingTimeInterval(-80), kind: .command, app: "Messages", text: "Neve should be Niamh.",
                         fixes: [], reply: "Got it: Neve → Niamh from now on", delivery: nil),
            event(-1500, AppEvent(time: now.addingTimeInterval(-1500), kind: .snapshot, folder: m1,
                                  file: NSHomeDirectory() + "/Documents/Speech Key Meetings/2026-11-04_1400_x7bm3z/part-01_00m00-14m10_2026-11-04_1400_x7bm3z.md",
                                  part: 1, seconds: 850)),
            dictation(-1700, "Chat", "Okay, here's the plan for the launch page. Keep it minimal: a header, one demo video, and a few closing lines."),
            event(-2400, AppEvent(time: now.addingTimeInterval(-2400), kind: .meetingStarted, folder: m1)),
            dictation(-4000, "Mail", "Hey Maya, can we push the design review to Thursday at two? Siobhan wants one more pass.",
                      fixes: ["Shivonne → Siobhan"]),
            dictation(-90000, "Notes", "Ideas for the offsite: clearer team goals, a shared calendar, and a budget review in week two.",
                      delivery: "copy"),
            event(-95000, AppEvent(time: now.addingTimeInterval(-95000), kind: .meetingEnded, folder: m2, seconds: 2950, snapshots: 4)),
            event(-96000, AppEvent(time: now.addingTimeInterval(-96000), kind: .glossaryEdited, heard: "Shivonne, Shivon", write: "Siobhan",
                                   notes: "design lead at the studio", oldHeard: "Shivonne", oldWrite: "Siobahn", source: "tab")),
        ]

        func makeModel(page: PanelModel.Page, empty: Bool = false) -> PanelModel {
            let history = History(log: DictationLog(), events: EventLog(enabled: false), loadFromDisk: false)
            history.replaceAll(empty ? [] : items)
            let m = PanelModel(history: history, glossary: GlossaryStore(path: glossaryFile))
            m.page = page
            m.status = "Ready"
            m.brainStatus = "Apple Intelligence, on this Mac · ready"
            m.glossaryPathLabel = "~/Library/Application Support/SpeechKey/glossary.md"
            m.meetingsPathLabel = "~/Documents/Speech Key Meetings"
            m.meetings = [
                MeetingSummary(folder: URL(fileURLWithPath: m1), started: now.addingTimeInterval(-2400), parts: 1, length: 851,
                               title: "Onboarding checklist with Priya",
                               summary: "Priya wants a three-step onboarding checklist with a progress bar before the beta.",
                               titleBy: "agent", snapshots: 2),
                MeetingSummary(folder: URL(fileURLWithPath: m2), started: now.addingTimeInterval(-95000), parts: 5, length: 2950,
                               title: "Weekly design sync",
                               summary: "Reviewed the launch page and agreed to keep it to one video and a short closing.",
                               titleBy: "agent", snapshots: 4),
                MeetingSummary(folder: URL(fileURLWithPath: "/tmp/speechkey-render/2026-11-01_0930_q2hd8n"), started: now.addingTimeInterval(-200000),
                               parts: 1, length: 610),
                MeetingSummary(folder: URL(fileURLWithPath: "/tmp/speechkey-render/2026-10-31_1815_vr6tme"), started: now.addingTimeInterval(-300000),
                               parts: 6, length: 3117, title: "Book club budget", summary: "Dues for the spring and who hosts in March.",
                               titleBy: "you", snapshots: 6),
            ]
            return m
        }

        var shots: [(String, PanelModel)] = []
        shots.append(("panel-1-history", makeModel(page: .history)))
        let live = makeModel(page: .history)
        live.meetingStartedAt = now.addingTimeInterval(-751)
        shots.append(("panel-2-meeting-live", live))
        let prompt = makeModel(page: .history)
        prompt.prompt = .init(item: items[0], newText: "", choices: [
            .init(heard: "Neve", correct: "Niamh", caution: PanelModel.caution(for: "Neve")),
        ])
        shots.append(("panel-3-glossary-prompt", prompt))
        let undo = makeModel(page: .history)
        undo.prompt = .init(item: items[0], newText: "", choices: [undo.choice(heard: "Elias Moreno", correct: "Eli")])
        shots.append(("panel-3b-glossary-prompt-undoes-name", undo))
        shots.append(("panel-4-meetings", makeModel(page: .meetings)))
        let liveMeetings = makeModel(page: .meetings)
        liveMeetings.meetingStartedAt = now.addingTimeInterval(-751)
        liveMeetings.meetings[0].snapshots = 1
        liveMeetings.meetings[2].title = "Hiring plan for spring"
        liveMeetings.meetings[2].summary = "Two engineers by March; Maya drafts the posting this week."
        shots.append(("panel-4b-meetings-live", liveMeetings))
        shots.append(("panel-5-glossary", makeModel(page: .glossary)))
        let used = makeModel(page: .glossary)
        used.glossarySort = .mostUsed
        shots.append(("panel-5b-glossary-most-used", used))
        let az = makeModel(page: .glossary)
        az.glossarySort = .alphabetical
        shots.append(("panel-5c-glossary-az", az))
        shots.append(("panel-6-settings", makeModel(page: .settings)))
        shots.append(("panel-7-empty", makeModel(page: .history, empty: true)))
        // The Raw switch: one row hovered (switch offered), one flipped to its raw words; and a name
        // learned from its spelling.
        let rawItems: [History.Item] = [
            History.Item(time: now.addingTimeInterval(-40), kind: .dictation, app: "Claude",
                         text: "So within the launch folder there's just the dated packets, and the Q&A page should generate the summary.",
                         raw: "Um, so s within the the launch folder there's just the dated packets, and the Q<unk>A page should generate generate the summary.",
                         fixes: [], reply: nil, delivery: nil),
            event(-110, AppEvent(time: now.addingTimeInterval(-110), kind: .glossaryAdded, heard: "Neve", write: "Niamh", source: "learned")),
            History.Item(time: now.addingTimeInterval(-120), kind: .dictation, app: "Claude",
                         text: "Send the draft to Niamh N-I-A-M-H and ask her what she thinks of the w white paper idea.",
                         raw: "Send the draft to Neve N-I-A-M-H and ask her what she thinks of the w white paper idea.",
                         fixes: ["Neve → Niamh"], reply: nil, delivery: nil),
            History.Item(time: now.addingTimeInterval(-400), kind: .dictation, app: "Slack",
                         text: "Can we move the review to Thursday at two?", raw: "Can we move the review to Thursday at two?",
                         fixes: [], reply: nil, delivery: nil),
        ]
        let rawModel = makeModel(page: .history)
        rawModel.history.replaceAll(rawItems)
        rawModel.showingRaw = [rawItems[0].id]
        rawModel.previewHover = rawItems[2].id
        shots.append(("panel-11-raw", rawModel))
        let copied = makeModel(page: .history)
        copied.copied = items[5].id
        shots.append(("panel-8-copied", copied))
        let editing = makeModel(page: .history)
        editing.editing = items[7].id
        shots.append(("panel-9-editing", editing))
        let search = makeModel(page: .history)
        search.historySearch = "Niamh"
        shots.append(("panel-10-search", search))

        // Naming the voices in a meeting: a real folder with a transcript, opened to its who's who.
        let voicesFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("speechkey-render/2026-11-04_1400_x7bm3z")
        try? FileManager.default.createDirectory(at: voicesFolder, withIntermediateDirectories: true)
        let sampleTranscript = """
        # Meeting 2026-11-04 14:00 · x7bm3z

        Length 14:11 · 1 part saved

        _Voices are told apart by sound; the numbers follow the order people first spoke. On your mic: Me, Priya. On the computer's audio: Speaker 1. A name can be wrong, most often on short lines and when people talk over each other._

        **[0:04] Speaker 1:** Thanks for making time. I mostly want to settle the launch date today, because marketing needs two weeks of notice before anything goes out.

        **[0:31] Me:** That works. Where are we on the onboarding checklist?

        **[0:48] Priya:** The three-step version is built and the progress bar is in. What I'm not sure about is whether people will finish step two without a nudge.

        **[6:20] Speaker 1:** If we slip a week I'd rather know now than the Friday before. Can we agree nothing new goes in after Wednesday?

        **[9:02] Priya:** I can live with that if the reminder email counts as already in. I'd also like five beta users to try it before we call it done.

        **[13:40] Speaker 1:** Fine by me. I'll tell marketing the nineteenth and send the notes around tonight.

        """
        try? sampleTranscript.write(to: voicesFolder.appendingPathComponent("full_2026-11-04_1400_x7bm3z.md"), atomically: true, encoding: .utf8)
        let sampleVoices = [
            MeetingMeta.Voice(label: "Speaker 1", name: nil, about: "Pushed to lock the launch date and stop new work after Wednesday so marketing gets notice."),
            MeetingMeta.Voice(label: "Speaker 2", name: "Priya", about: "Built the onboarding checklist and wanted beta users to try it before calling it done."),
        ]
        var sampleMeta = MeetingMeta()
        sampleMeta.title = "Onboarding checklist with Priya"
        sampleMeta.voices = sampleVoices
        sampleMeta.save(to: voicesFolder)
        let who = makeModel(page: .meetings)
        who.meetings[0] = MeetingSummary(folder: voicesFolder, started: now.addingTimeInterval(-2400), parts: 1, length: 851,
                                         title: "Onboarding checklist with Priya",
                                         summary: "Priya wants a three-step onboarding checklist with a progress bar before the beta.",
                                         titleBy: "agent", snapshots: 2, voices: sampleVoices)
        who.meetings[1].voices = [MeetingMeta.Voice(label: "Speaker 1"), MeetingMeta.Voice(label: "Speaker 2"), MeetingMeta.Voice(label: "Speaker 3")]
        who.meetings[3].voices = [MeetingMeta.Voice(label: "Them", name: "Dana")]
        who.toggleVoices(who.meetings[0])
        shots.append(("panel-12-whos-who", who))

        for (name, model) in shots {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                PillRenderer.write(PanelView(model: model, history: model.history, solidBackground: true),
                                   to: "\(dir)/\(name)-\(suffix).png", appearance: appearance)
            }
        }
        // The first-run window: mid-download with nothing granted yet, and all done with a full menu bar.
        let fresh = SetupModel()
        fresh.download = 0.43
        let done = SetupModel()
        done.mic = true; done.micAsked = true; done.keys = true; done.paste = true; done.globe = true
        done.engine = .ready; done.iconHidden = true
        for (name, model) in [("setup-1-downloading", fresh), ("setup-2-done-icon-hidden", done)] {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                PillRenderer.write(SetupView(model: model) {}.background(Color(nsColor: .windowBackgroundColor)),
                                   to: "\(dir)/\(name)-\(suffix).png", appearance: appearance)
            }
        }
        print("rendered panel to \(dir)")
    }
}
