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
        let copied = makeModel(page: .history)
        copied.copied = items[5].id
        shots.append(("panel-8-copied", copied))
        let editing = makeModel(page: .history)
        editing.editing = items[7].id
        shots.append(("panel-9-editing", editing))
        let search = makeModel(page: .history)
        search.historySearch = "Niamh"
        shots.append(("panel-10-search", search))

        for (name, model) in shots {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                PillRenderer.write(PanelView(model: model, history: model.history, solidBackground: true),
                                   to: "\(dir)/\(name)-\(suffix).png", appearance: appearance)
            }
        }
        print("rendered panel to \(dir)")
    }
}
