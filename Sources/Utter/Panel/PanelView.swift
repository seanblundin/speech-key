import AppKit
import SwiftUI
import SpeechEngine

/// The menu-bar panel (Sean, 2026-10-21): a wide History | Meetings | Glossary pill and a gear.
/// History is everything that happened, newest first; one click copies a dictation.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var history: History
    /// Design review renders on a solid background; the real popover supplies its own material.
    var solidBackground = false

    static let size = CGSize(width: 460, height: 640)

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                TopBar(model: model)
                if model.meetingStartedAt != nil {
                    LiveMeetingBar(model: model).padding(.horizontal, 12).padding(.bottom, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                ForEach(model.problems) { p in ProblemCard(problem: p).padding(.horizontal, 12).padding(.bottom, 8) }
                Group {
                    switch model.page {
                    case .history: HistoryPage(model: model, history: history)
                    case .meetings: MeetingsPage(model: model)
                    case .glossary: GlossaryPage(model: model, glossary: model.glossary)
                    case .settings: SettingsPage(model: model)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
            }

            if model.prompt != nil { GlossaryPromptView(model: model).transition(.opacity) }

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule(style: .continuous).fill(Color(white: 0.08).opacity(0.92)))
                        .padding(.bottom, 14)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }

            // ⌘Q, since there's no menu.
            Button("") { model.actions.quit() }.keyboardShortcut("q").opacity(0).frame(width: 0, height: 0)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(solidBackground ? Color(nsColor: .windowBackgroundColor) : .clear)
        .animation(.easeOut(duration: 0.16), value: model.page)
        .animation(.easeOut(duration: 0.18), value: model.meetingStartedAt != nil)
        .animation(.easeOut(duration: 0.16), value: model.prompt != nil)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.toast)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 8) {
            SegmentedPill(options: [(PanelModel.Page.history, "History"), (.meetings, "Meetings"), (.glossary, "Glossary")],
                          selection: Binding(get: { model.page == .settings ? nil : model.page },
                                             set: { if let p = $0 { model.page = p } }),
                          height: 32)
            IconButton(symbol: model.page == .settings ? "gearshape.fill" : "gearshape", help: "Settings",
                       active: model.page == .settings, size: 32) {
                model.page = model.page == .settings ? .history : .settings
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
    }
}

/// A wide pill of choices with a sliding selection: the tabs, and Paste · Copy · Save.
struct SegmentedPill<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value?
    var height: CGFloat = 30
    @Namespace private var ns
    @Environment(\.colorScheme) private var scheme

    init(options: [(Value, String)], selection: Binding<Value?>, height: CGFloat = 30) {
        self.options = options
        self._selection = selection
        self.height = height
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Segment(title: title, selected: selection == value, height: height - 6, ns: ns, scheme: scheme) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { selection = value }
                }
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(scheme == .dark ? 0.09 : 0.065)))
    }

    private struct Segment: View {
        let title: String
        let selected: Bool
        let height: CGFloat
        let ns: Namespace.ID
        let scheme: ColorScheme
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background {
                        if selected {
                            Capsule(style: .continuous)
                                .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white)
                                .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.10), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "selection", in: ns)
                        } else if hovering {
                            Capsule(style: .continuous).fill(Color.primary.opacity(0.05))
                        }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

/// While a meeting records: a red bar on every tab, with Snapshot and End.
private struct LiveMeetingBar: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if let started = model.meetingStartedAt {
            HStack(spacing: 8) {
                PulsingDot()
                Text("Recording").font(.system(size: 13, weight: .semibold))
                TimelineView(.periodic(from: started, by: 1)) { ctx in
                    Text(MeetingTranscript.clock(ctx.date.timeIntervalSince(started)))
                        .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
                Spacer(minLength: 0)
                SmallButton(title: "Snapshot", symbol: "camera.viewfinder") { model.actions.snapshot() }
                SmallButton(title: "End", symbol: "stop.fill") { model.actions.endMeeting() }
            }
            .padding(.leading, 12).padding(.trailing, 6)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(nsColor: .systemRed).opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color(nsColor: .systemRed).opacity(0.25), lineWidth: 1))
        }
    }
}

// MARK: - History

private struct HistoryPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var history: History

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.historySearch, placeholder: "Search history").padding(.horizontal, 12).padding(.bottom, 6)
            if history.items.isEmpty {
                EmptyHistory(model: model)
            } else {
                let days = model.historyDays
                if days.isEmpty {
                    EmptyNote(title: "Nothing matches", detail: "Try another word.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(days, id: \.day) { group in
                                DayLabel(group.day)
                                ForEach(group.items) { item in HistoryRow(item: item, model: model) }
                            }
                        }
                        .padding(.horizontal, 6).padding(.bottom, 12)
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let item: History.Item
    @ObservedObject var model: PanelModel

    var body: some View {
        switch item.kind {
        case .dictation: DictationRow(item: item, model: model)
        case .command: CommandRow(item: item)
        case .event(let kind):
            switch kind {
            case .glossaryAdded, .glossaryRemoved, .glossaryEdited: GlossaryEventRow(item: item, model: model)
            default: MeetingEventRow(item: item, model: model)
            }
        }
    }
}

/// One dictation. Click copies it; double-click a word to fix it.
private struct DictationRow: View {
    let item: History.Item
    @ObservedObject var model: PanelModel
    @State private var draft: String
    @State private var hovering = false

    init(item: History.Item, model: PanelModel) {
        self.item = item
        self.model = model
        _draft = State(initialValue: item.text)
    }

    private var editing: Bool { model.editing == item.id }
    private var copied: Bool { model.copied == item.id }

    private var fixes: [(heard: String, correct: String)] {
        item.fixes.compactMap { f in
            let bits = f.components(separatedBy: " → ")
            return bits.count == 2 ? (bits[0], bits[1]) : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EditableText(text: $draft, fixes: fixes, isEditing: editing,
                         onClick: { model.copyItem(item) },
                         onDoubleClick: { model.copied = nil; model.editing = item.id },
                         onCommit: { model.commit(item, newText: draft) },
                         onCancel: { draft = item.text; model.editing = nil },
                         onEndEditing: { if model.editing == item.id { draft = item.text; model.editing = nil } })
            HStack(spacing: 4) {
                Text(PanelFormat.clockTime(item.time))
                if let app = item.app { Text("·"); Text(app) }
                if let d = item.delivery { Text("·"); Text(d == "copy" ? "Copied only" : "Saved") }
                Spacer()
                if editing {
                    Text("↩ save   esc cancel").foregroundStyle(.secondary)
                } else if copied {
                    Label("Copied", systemImage: "checkmark").foregroundStyle(Color(nsColor: .systemGreen))
                } else if hovering {
                    Text("Click to copy · double-click to edit")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(editing ? 0.45 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if !editing { model.copyItem(item) } }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: copied)
        .animation(.easeOut(duration: 0.1), value: hovering)
        // Reverts happen only on cancel (above). Reverting whenever editing ended raced the save
        // and put the old text back on screen (2026-10-20).
        .onChange(of: item.text) { draft = $0 }
        // Double-clicking another row abandons this edit. Read the saved text fresh from history:
        // the captured `item` can be a stale copy.
        .onChange(of: model.editing) { now in
            if now != item.id, let saved = model.history.items.first(where: { $0.id == item.id })?.text { draft = saved }
        }
    }

    private var fill: Color {
        if editing { return Color.accentColor.opacity(0.07) }
        if copied { return Color(nsColor: .systemGreen).opacity(0.08) }
        return Color.primary.opacity(hovering ? 0.05 : 0)
    }
}

/// A conversation with the agent (⇧ fn): what Sean said, and what it did or answered.
private struct CommandRow: View {
    let item: History.Item
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(PillModel.utterTint)
                .frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("“\(item.text)”").font(.system(size: 13)).foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    if let reply = item.reply {
                        Text(reply).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    Text(PanelFormat.clockTime(item.time)).foregroundStyle(.tertiary)
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
    }
}

/// A meeting starting or ending, or a snapshot. Quiet, one line; click copies the file's path.
private struct MeetingEventRow: View {
    let item: History.Item
    @ObservedObject var model: PanelModel
    @State private var hovering = false

    private var e: AppEvent { item.event! }

    private var symbol: (String, Color) {
        switch e.kind {
        case .meetingStarted: return ("record.circle", Color(nsColor: .systemRed))
        case .meetingEnded: return ("stop.circle", .secondary)
        default: return ("camera.viewfinder", .secondary)
        }
    }

    private var headline: String {
        switch e.kind {
        case .meetingStarted: return "Meeting started"
        case .meetingEnded:
            var bits = ["Meeting ended"]
            if let s = e.seconds { bits.append(PanelFormat.duration(s)) }
            if let n = e.snapshots, n > 0 { bits.append(PanelFormat.snapshots(n)) }
            return bits.joined(separator: " · ")
        default:
            var s = "Snapshot"
            if let p = e.part { s += " \(p)" }
            if let t = e.seconds { s += " at \(MeetingTranscript.clock(t))" }
            return s
        }
    }

    /// What clicking copies.
    private var path: String? {
        if let f = e.file { return f }
        guard let folder = e.folder else { return nil }
        let full = URL(fileURLWithPath: folder).appendingPathComponent("full.md").path
        return FileManager.default.fileExists(atPath: full) ? full : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol.0).font(.system(size: 12, weight: .medium)).foregroundStyle(symbol.1)
                .frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary.opacity(0.8))
                if let title = model.title(forFolder: e.folder) {
                    Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                } else if let f = e.file {
                    Text(PanelFormat.tilde(f)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if model.copied == item.id {
                Label("Path copied", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemGreen))
            } else if hovering, path != nil {
                Text("Copy path").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                Text(PanelFormat.clockTime(item.time)).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(model.copied == item.id ? Color(nsColor: .systemGreen).opacity(0.08) : Color.primary.opacity(hovering && path != nil ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { if let path { model.copyPath(path, for: item.id) } }
        .onHover { hovering = $0 }
        .help(path.map { "Click to copy \($0)" } ?? "")
    }
}

/// A glossary change: "Neve → Niamh", where it came from, and an Undo.
private struct GlossaryEventRow: View {
    let item: History.Item
    @ObservedObject var model: PanelModel
    @State private var hovering = false

    private var e: AppEvent { item.event! }

    private var verb: String {
        switch e.kind {
        case .glossaryAdded: return "Added to glossary"
        case .glossaryRemoved: return "Removed from glossary"
        default: return "Edited in glossary"
        }
    }

    private var from: String {
        switch e.source {
        case "voice": return "by voice"
        case "panel": return "from a fixed word"
        case "tab": return "in the Glossary tab"
        case "undo": return "undo"
        default: return ""
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "character.book.closed").font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(PillModel.utterTint).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                FixLabel(heard: e.heard ?? "", write: e.write ?? "", removed: e.kind == .glossaryRemoved)
                Text([verb, from].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                if e.kind == .glossaryEdited, let oldWrite = e.oldWrite {
                    Text("was \(e.oldHeard.map { $0.isEmpty ? "" : "\($0) → " } ?? "")\(oldWrite)")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            let undoable = hovering && e.source != "undo"
            ZStack(alignment: .trailing) {
                Text(PanelFormat.clockTime(item.time)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .opacity(undoable ? 0 : 1)
                if e.source != "undo" {
                    SmallButton(title: "Undo", symbol: "arrow.uturn.backward") { model.revert(e) }
                        .opacity(undoable ? 1 : 0)
                        .allowsHitTesting(undoable)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        .onHover { hovering = $0 }
    }
}

/// "Neve → Niamh", with the heard word struck through.
private struct FixLabel: View {
    let heard: String
    let write: String
    var removed = false
    var body: some View {
        HStack(spacing: 6) {
            if !heard.isEmpty {
                Text(heard).strikethrough(!removed, color: .secondary).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
            }
            Text(write).fontWeight(.semibold).strikethrough(removed, color: .secondary)
                .foregroundStyle(removed ? .secondary : .primary)
        }
        .font(.system(size: 13))
        .lineLimit(1)
    }
}

private struct EmptyHistory: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Keys([Keys.globe], size: 20)
            VStack(spacing: 4) {
                Text(model.isReady ? "Hold to talk" : model.status).font(.system(size: 14, weight: .semibold))
                Text("Everything you say and do in Speech Key shows up here.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Meetings

private struct MeetingsPage: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.meetingStartedAt == nil {
                    WideButton(symbol: "record.circle", title: "Start meeting", tint: Color(nsColor: .systemRed),
                               keys: ["⌃", "⌥", Keys.globe]) { model.actions.startMeeting() }
                } else {
                    WideButton(symbol: "camera.viewfinder", title: "Snapshot", tint: .secondary,
                               keys: ["⌃", Keys.globe]) { model.actions.snapshot() }
                }
                WideButton(symbol: "folder", title: "Meetings folder", tint: .secondary, keys: []) { model.actions.openMeetingsFolder() }
            }
            .padding(.horizontal, 12).padding(.bottom, 4)

            if model.meetings.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Keys(["⌃", "⌥", Keys.globe], size: 15)
                    Text("No meetings yet").font(.system(size: 14, weight: .semibold))
                    Text("Start one before you join the call.\nTell everyone it's being transcribed.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer(); Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(PanelFormat.byDay(model.meetings, date: \.started), id: \.day) { group in
                            DayLabel(group.day)
                            ForEach(group.items) { m in MeetingRow(meeting: m, model: model) }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 12)
                }
            }
        }
    }
}

/// One saved meeting: its title (by the agent, or Sean's own), a line of summary, and the facts.
/// Click copies the transcript's path; the pencil renames it; the folder shows it in Finder.
private struct MeetingRow: View {
    let meeting: MeetingSummary
    @ObservedObject var model: PanelModel
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var titleFocused: Bool

    private var renaming: Bool { model.renaming == meeting.folder }
    private var copied: Bool { model.copiedMeeting == meeting.folder }
    private var titling: Bool { model.titling.contains(meeting.folder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if renaming {
                    TextField("Title", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, weight: .semibold))
                        .focused($titleFocused)
                        .onSubmit { model.rename(meeting, to: draft) }
                        .onExitCommand { model.renaming = nil }
                        .onAppear { draft = meeting.title ?? ""; titleFocused = true }
                } else if let title = meeting.title {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                } else {
                    Text(titling ? "Writing a title…" : "Untitled meeting")
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if renaming {
                    Text("↩ save   esc cancel").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    // Always laid out, only shown on hover, so rows keep their size (Sean, 2026-10-22).
                    HStack(spacing: 6) {
                        IconButton(symbol: "pencil", help: "Rename", size: 22) { model.renaming = meeting.folder }
                        IconButton(symbol: "folder", help: "Show in Finder", size: 22) {
                            NSWorkspace.shared.activateFileViewerSelecting([meeting.mainFile])
                        }
                    }
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                }
            }
            .frame(height: 22)
            if let summary = meeting.summary, !renaming {
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                if copied {
                    Label("Path copied", systemImage: "checkmark").foregroundStyle(Color(nsColor: .systemGreen))
                } else {
                    Text(PanelFormat.meetingDetail(meeting))
                    if meeting.titleBy == "agent" && hovering {
                        Text("·"); Image(systemName: "sparkle").foregroundStyle(PillModel.utterTint); Text("titled by the agent")
                    }
                }
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(copied ? Color(nsColor: .systemGreen).opacity(0.08) : Color.primary.opacity(hovering || renaming ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { if !renaming { model.copyMeeting(meeting) } }
        .onHover { hovering = $0 }
        .onChange(of: titleFocused) { focused in if !focused && renaming { model.rename(meeting, to: draft) } }
        .help("Click to copy the path: \(meeting.mainFile.path)")
    }
}

// MARK: - Glossary

private struct GlossaryPage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var glossary: GlossaryStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField(text: $model.glossarySearch, placeholder: "Search glossary")
                Button {
                    model.glossarySearch = ""
                    model.focusGlossaryRow = glossary.newRow().id
                } label: {
                    HStack(spacing: 4) { Image(systemName: "plus"); Text("New") }
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.07)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .hoverHighlight(radius: 15)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)

            HStack(spacing: 10) {
                SegmentedPill(options: [(PanelModel.GlossarySort.recent, "Recent"), (.mostUsed, "Most used"), (.alphabetical, "A–Z")],
                              selection: Binding(get: { model.glossarySort }, set: { if let s = $0 { model.glossarySort = s } }),
                              height: 28)
                    .frame(width: 252)
                Spacer()
                if model.glossarySort == .mostUsed {
                    Text("uses in the last 7 days").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)

            HStack(spacing: 8) {
                ColumnLabel("Heard as").frame(width: GlossaryCell.heardWidth, alignment: .leading)
                ColumnLabel("Write as").frame(width: GlossaryCell.writeWidth, alignment: .leading)
                ColumnLabel("Notes")
                Spacer()
                Text("\(glossary.rows.filter { !$0.isEmpty }.count)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20).padding(.bottom, 4)
            Divider().padding(.horizontal, 12)

            let rows = model.glossaryRows
            if rows.isEmpty {
                EmptyNote(title: model.glossarySearch.isEmpty ? "Your glossary is empty" : "Nothing matches",
                          detail: model.glossarySearch.isEmpty ? "Add a name Speech Key gets wrong, and how to write it." : "Try another word.")
            } else {
                let uses = model.glossarySort == .mostUsed ? model.glossaryUses : nil
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            GlossaryRowView(row: row, model: model, uses: uses.map { $0[row.write.lowercased()] ?? 0 })
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
        }
    }
}

private enum GlossaryCell { static let heardWidth: CGFloat = 112, writeWidth: CGFloat = 112 }

/// One editable row. Changes save when you press Return or leave the field.
private struct GlossaryRowView: View {
    let row: GlossaryStore.Row
    @ObservedObject var model: PanelModel
    /// Times used in the last 7 days, when sorting by Most used.
    let uses: Int?
    @State private var heard: String
    @State private var write: String
    @State private var notes: String
    @State private var hovering = false
    @FocusState private var focus: Field?
    enum Field: Hashable { case heard, write, notes }

    init(row: GlossaryStore.Row, model: PanelModel, uses: Int? = nil) {
        self.row = row
        self.model = model
        self.uses = uses
        _heard = State(initialValue: row.heard)
        _write = State(initialValue: row.write)
        _notes = State(initialValue: row.notes)
    }

    private var unconfirmed: Bool { row.notes.lowercased().hasPrefix("unconfirmed") }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            cell($heard, prompt: "listen for", width: GlossaryCell.heardWidth, field: .heard)
                .foregroundStyle(.secondary)
            cell($write, prompt: "write as", width: GlossaryCell.writeWidth, field: .write)
                .fontWeight(.semibold)
            cell($notes, prompt: row.isEmpty || focus == .notes ? "notes" : "", width: nil, field: .notes)
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            ZStack(alignment: .trailing) {
                if let uses, uses > 0 {
                    Text("\(uses)×").font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
                        .opacity(hovering ? 0 : 1)
                        .help("Used \(uses) time\(uses == 1 ? "" : "s") in the last 7 days")
                }
                Button { model.deleteGlossaryRow(row.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary).opacity(hovering ? 1 : 0).allowsHitTesting(hovering).help("Remove")
            }
            .frame(width: 26, alignment: .trailing)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(focus != nil ? Color.accentColor.opacity(0.07) : Color.primary.opacity(hovering ? 0.045 : 0)))
        .opacity(unconfirmed && focus == nil ? 0.55 : 1)
        .onHover { hovering = $0 }
        .onChange(of: focus) { now in if now == nil { save() } }
        .onChange(of: row.heard) { heard = $0 }
        .onChange(of: row.write) { write = $0 }
        .onChange(of: row.notes) { notes = $0 }
        .onAppear {
            if model.focusGlossaryRow == row.id { focus = .heard; model.focusGlossaryRow = nil }
        }
    }

    private func cell(_ text: Binding<String>, prompt: String, width: CGFloat?, field: Field) -> some View {
        TextField(prompt, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .focused($focus, equals: field)
            .onSubmit { focus = nil }
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : width, alignment: .leading)
    }

    private func save() {
        var updated = row
        updated.heard = heard; updated.write = write; updated.notes = notes
        if updated.isEmpty { model.glossary.discardIfBlank(row.id); return }
        guard updated.heard != row.heard || updated.write != row.write || updated.notes != row.notes else { return }
        guard !updated.write.trimmingCharacters(in: .whitespaces).isEmpty else { return }   // needs a spelling to save
        model.saveGlossaryRow(updated)
    }
}

private struct ColumnLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    @ObservedObject var model: PanelModel
    @AppStorage(AfterDictation.key) private var afterDictation = AfterDictation.paste.rawValue
    @State private var advancedShortcuts = false

    private var afterHint: String {
        switch AfterDictation(rawValue: afterDictation) ?? .paste {
        case .paste: return "Your words appear wherever you’re typing."
        case .copy: return "Your words go to your clipboard, ready for ⌘V."
        case .save: return "Your words wait in History. Click one to copy it."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsSection(title: Text("Shortcuts")) {
                        ShortcutRow("Talk", hint: "hold", keys: [Keys.globe])
                        ShortcutRow("Start or end a meeting", hint: nil, keys: ["⌃", "⌥", Keys.globe])
                        ShortcutRow("Meeting snapshot", hint: nil, keys: ["⌃", Keys.globe])
                        ShortcutRow("Talk to Agent", hint: "hold", keys: ["⇧", Keys.globe], utter: true)
                        AdvancedShortcuts(expanded: $advancedShortcuts)
                    }

                    SettingsSection(title: Text("After you release \(Image(systemName: "globe"))")) {
                        SegmentedPill(options: [(AfterDictation.paste.rawValue, "Paste"), (AfterDictation.copy.rawValue, "Copy"),
                                                (AfterDictation.save.rawValue, "Save")],
                                      selection: Binding(get: { afterDictation }, set: { if let v = $0 { afterDictation = v } }))
                        Text(afterHint).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SettingsSection(title: Text("General")) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkle").foregroundStyle(PillModel.utterTint).font(.system(size: 12, weight: .semibold))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Talk to Agent · \(model.brainStatus)").font(.system(size: 13))
                                Text("Try “Jammy should be Jimmy”, “remove Jimmy”, “start a meeting”, “take a snapshot”, or “undo that”.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Glossary file").font(.system(size: 13))
                                Spacer()
                                SmallButton(title: "Open", symbol: nil) { model.actions.openGlossary() }
                            }
                            PathRow(label: model.glossaryPathLabel) { model.actions.chooseGlossary() }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Meetings folder").font(.system(size: 13))
                            PathRow(label: model.meetingsPathLabel) { model.actions.chooseMeetingsFolder() }
                        }
                        Divider()
                        Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                                set: { model.actions.setLaunchAtLogin($0) }))
                            .toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
                        LinkRow("Permissions and setup") { model.actions.showSetup() }
                        LinkRow("Open dictation log") { model.actions.openLog() }
                        if AppUpdates.available {
                            LinkRow("Check for updates…") { AppUpdates.checkNow() }
                        }
                        Divider()
                        // The speech models are CC-BY-4.0, which asks for this credit.
                        Text("Speech recognition by NVIDIA Parakeet TDT 0.6B (Moondream's Ultra fine-tune) and Parakeet CTC 110M, CC-BY-4.0, converted to Core ML by FluidInference. Runs on FluidAudio (Apache-2.0) and Silero VAD (MIT).")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        LinkRow("Licenses") {
                            if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") { NSWorkspace.shared.open(url) }
                        }
                        LinkRow("Source code") {
                            NSWorkspace.shared.open(URL(string: "https://github.com/seanblundin/speech-key")!)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
            }
            Divider()
            HStack {
                Circle().fill(Color(nsColor: model.statusColor)).frame(width: 6, height: 6)
                Text("Speech: \(model.status)").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                SmallButton(title: "Quit Speech Key", symbol: nil) { model.actions.quit() }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: Text
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            title.font(.system(size: 10.5, weight: .semibold)).tracking(0.6).textCase(.uppercase).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 9) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
        }
    }
}

/// The hands-free chords and Esc, folded away: the four everyday shortcuts are enough for most days.
private struct AdvancedShortcuts: View {
    @Binding var expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Advanced shortcuts")
                    Spacer()
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(radius: 6, inset: -4)

            if expanded {
                AdvancedRow(title: "Talk hands-free", keys: [Keys.globe], hint: "tap twice",
                            detail: "Keeps listening after you let go. Tap \(Image(systemName: "globe")) once more to finish.")
                AdvancedRow(title: "Talk to Agent hands-free", keys: ["⇧", "⌃", "⌥", Keys.globe], hint: nil, utter: true,
                            detail: "Same, for the agent. Tap \(Image(systemName: "globe")) once more to finish.")
                AdvancedRow(title: "Cancel", keys: ["esc"], hint: nil,
                            detail: "Throws away what you're saying, held or hands-free. Nothing is pasted.")
                Text("Shortcut keys can go down in any order; Speech Key reads them when \(Image(systemName: "globe")) comes up.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AdvancedRow: View {
    let title: String
    let keys: [String]
    let hint: String?
    var utter = false
    let detail: LocalizedStringKey
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ShortcutRow(title, hint: hint, keys: keys, utter: utter)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let hint: String?
    let keys: [String]
    var utter = false
    init(_ title: String, hint: String?, keys: [String], utter: Bool = false) {
        self.title = title; self.hint = hint; self.keys = keys; self.utter = utter
    }
    var body: some View {
        HStack(spacing: 6) {
            if utter { Image(systemName: "sparkle").font(.system(size: 9, weight: .semibold)).foregroundStyle(PillModel.utterTint) }
            Text(title).font(.system(size: 13))
            Spacer()
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary) }
            Keys(keys)
        }
    }
}

/// A file or folder location, with a button to pick another.
private struct PathRow: View {
    let label: String
    let change: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button(action: change) { Text("Change…").padding(.horizontal, 6).padding(.vertical, 2) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                .hoverHighlight(radius: 5)
        }
    }
}

private struct LinkRow: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(radius: 6, inset: -5)
    }
}

// MARK: - Glossary prompt

private struct GlossaryPromptView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.22).onTapGesture { model.answerPrompt(add: false) }
            if let prompt = model.prompt {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Fix this every time?").font(.system(size: 15, weight: .semibold))
                        Text("Saved and copied. Speech Key can also remember the fix.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(prompt.choices.enumerated()), id: \.element.id) { i, c in
                        HStack(alignment: .top, spacing: 8) {
                            if prompt.choices.count > 1 || prompt.choices.contains(where: \.undoesGlossaryName) {
                                Toggle("", isOn: Binding(get: { model.prompt?.choices[i].include ?? false },
                                                         set: { model.prompt?.choices[i].include = $0 }))
                                    .toggleStyle(.checkbox).labelsHidden()
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                FixLabel(heard: c.heard, write: c.correct).font(.system(size: 14))
                                if let caution = c.caution {
                                    Text(caution).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    // With nothing ticked, Return means "Just this once".
                    let adding = prompt.choices.contains(where: \.include)
                    HStack {
                        Spacer()
                        Button("Just this once") { model.answerPrompt(add: false) }
                            .keyboardShortcut(adding ? .cancelAction : .defaultAction)
                        Button("Add to glossary") { model.answerPrompt(add: true) }
                            .keyboardShortcut(adding ? .defaultAction : nil)
                            .buttonStyle(.borderedProminent)
                            .disabled(!adding)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                .padding(10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Small pieces

private struct ProblemCard: View {
    let problem: PanelModel.Problem
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemOrange))
            Text(problem.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(problem.button, action: problem.fix).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .systemOrange).opacity(0.10)))
    }
}

private struct SearchField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12.5)).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(focused ? 0.075 : hovering ? 0.065 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(focused ? 0.35 : 0), lineWidth: 1))
        .onHover { hovering = $0 }
        .onTapGesture { focused = true }
    }
}

/// A wide action button, like "Start meeting ⌃⌥🌐" at the top of Meetings.
private struct WideButton: View {
    let symbol: String
    let title: String
    let tint: Color
    let keys: [String]
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12.5, weight: .medium)).foregroundStyle(tint)
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 4)
                if !keys.isEmpty { Keys(keys, size: 9.5) }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.085 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A compact pill button with a hover state (Snapshot, End, Undo, Open, Quit).
private struct SmallButton: View {
    let title: String
    let symbol: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text(title)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule(style: .continuous).fill(Color.primary.opacity(hovering ? 0.13 : 0.075)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Keys: View {
    /// The globe (fn) key, drawn as its symbol.
    static let globe = "globe"
    let keys: [String]
    var size: CGFloat = 10.5
    init(_ keys: [String], size: CGFloat = 10.5) { self.keys = keys; self.size = size }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { k in
                Group { if k == Self.globe { Image(systemName: "globe").font(.system(size: size * 0.95, weight: .medium)) } else { Text(k) } }
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, size * 0.45)
                    .frame(minWidth: size * 1.7, minHeight: size * 1.65)
                    .background(RoundedRectangle(cornerRadius: size * 0.38, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.38, style: .continuous).strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.8))
            }
        }
        .fixedSize()
    }
}

private struct DayLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }
}

private struct EmptyNote: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 4) {
            Spacer()
            Text(title).font(.system(size: 13.5, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(active ? .primary : .secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(active ? 0.1 : hovering ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).help(help).onHover { hovering = $0 }
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Color(nsColor: .systemRed)).frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true } }
    }
}

/// Hovering anything clickable highlights it, like every other Mac UI (Sean, 2026-10-21).
private struct HoverHighlight: ViewModifier {
    var radius: CGFloat
    var inset: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                .padding(inset))
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = 8, inset: CGFloat = 0) -> some View {
        modifier(HoverHighlight(radius: radius, inset: inset))
    }
}

enum PanelFormat {
    static func time(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return clockTime(d) }
        if cal.isDateInYesterday(d) { return "Yesterday " + clockTime(d) }
        return d.formatted(.dateTime.month(.abbreviated).day()) + ", " + clockTime(d)
    }

    static func clockTime(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    static func duration(_ len: TimeInterval) -> String {
        len < 60 ? "\(Int(len)) s" : len < 3600 ? "\(Int((len / 60).rounded())) min"
            : String(format: "%d h %02d min", Int(len) / 3600, (Int(len) % 3600) / 60)
    }

    static func meetingDetail(_ m: MeetingSummary) -> String {
        var bits = [clockTime(m.started)]
        if let len = m.length { bits.append(duration(len)) }
        if m.snapshotCount > 0 { bits.append(snapshots(m.snapshotCount)) }
        return bits.joined(separator: " · ")
    }

    /// A finished meeting never has 1 (see `MeetingTranscript.snapshotCount`), but a live one can.
    static func snapshots(_ n: Int) -> String { n == 1 ? "1 snapshot" : "\(n) snapshots" }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func dayName(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let y = cal.dateComponents([.year], from: d).year, y != cal.component(.year, from: Date()) {
            return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
        }
        return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    static func byDay<T>(_ items: [T], date: KeyPath<T, Date>) -> [(day: String, items: [T])] {
        var groups: [(String, [T])] = []
        for item in items {
            let day = dayName(item[keyPath: date])
            if groups.last?.0 == day { groups[groups.count - 1].1.append(item) } else { groups.append((day, [item])) }
        }
        return groups.map { (day: $0.0, items: $0.1) }
    }
}
