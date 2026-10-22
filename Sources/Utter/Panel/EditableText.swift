import AppKit
import SwiftUI

/// A paragraph that reads as plain text. One click copies it; a double-click starts editing with
/// the clicked word selected, so typing replaces it. Return saves, Esc cancels, ⇧↩ adds a line.
///
/// An AppKit text view rather than a SwiftUI TextField, because it can tell one click from two,
/// select the word under the pointer, and let Return mean "done".
struct EditableText: NSViewRepresentable {
    @Binding var text: String
    /// Words Utter fixed on its own, underlined with a tooltip saying what it heard.
    var fixes: [(heard: String, correct: String)] = []
    var isEditing: Bool
    var font: NSFont = .systemFont(ofSize: 13)
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Editing ended some other way (clicked elsewhere, panel closed).
    var onEndEditing: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CommitTextView {
        let v = CommitTextView()
        v.delegate = context.coordinator
        v.isRichText = false
        v.isEditable = false
        v.isSelectable = false
        v.drawsBackground = false
        v.isVerticallyResizable = false
        v.isHorizontallyResizable = false
        v.textContainerInset = .zero
        v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = true
        v.font = font
        v.textColor = .labelColor
        v.allowsUndo = true
        v.isAutomaticQuoteSubstitutionEnabled = false
        v.isAutomaticDashSubstitutionEnabled = false
        v.isAutomaticTextReplacementEnabled = false
        v.isAutomaticSpellingCorrectionEnabled = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.show(text, in: v)
        return v
    }

    func updateNSView(_ v: CommitTextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        v.onClick = onClick
        v.onDoubleClick = { [weak c] index in c?.pendingWord = index; c?.parent.onDoubleClick() }
        v.onCommit = onCommit
        v.onCancel = onCancel
        v.onResign = { [weak c] in c?.parent.onEndEditing() }

        if isEditing, !v.isEditable {
            v.isEditable = true
            v.isSelectable = true
            v.window?.makeFirstResponder(v)
            // Select the double-clicked word, so typing replaces it.
            let index = min(c.pendingWord ?? (v.string as NSString).length, (v.string as NSString).length)
            let word = v.selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord)
            v.setSelectedRange(word)
            c.pendingWord = nil
        } else if !isEditing, v.isEditable {
            v.isEditable = false
            v.isSelectable = false
            if v.window?.firstResponder === v { v.window?.makeFirstResponder(nil) }
        }
        if v.string != text, !v.isEditable { c.show(text, in: v) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: CommitTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 360
        guard let layout = v.layoutManager, let container = v.textContainer else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = max(layout.usedRect(for: container).height, font.boundingRectForFont.height * 0.9)
        return CGSize(width: width, height: ceil(height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableText
        var pendingWord: Int?
        init(_ parent: EditableText) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let v = note.object as? NSTextView else { return }
            parent.text = v.string
        }

        /// Sets the text and marks the words Utter fixed.
        func show(_ text: String, in v: NSTextView) {
            let s = NSMutableAttributedString(string: text, attributes: [.font: parent.font, .foregroundColor: NSColor.labelColor])
            let ns = text as NSString
            for fix in parent.fixes where !fix.correct.isEmpty {
                var search = NSRange(location: 0, length: ns.length)
                while true {
                    let r = ns.range(of: fix.correct, options: [], range: search)
                    guard r.location != NSNotFound else { break }
                    s.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                     .underlineColor: NSColor(srgbRed: 0.66, green: 0.58, blue: 1.0, alpha: 1),
                                     .toolTip: "Speech Key heard “\(fix.heard)”"], range: r)
                    let next = r.location + r.length
                    search = NSRange(location: next, length: ns.length - next)
                }
            }
            v.textStorage?.setAttributedString(s)
            v.typingAttributes = [.font: parent.font, .foregroundColor: NSColor.labelColor]
        }
    }
}

final class CommitTextView: NSTextView {
    var onClick: () -> Void = {}
    var onDoubleClick: (Int) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onResign: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        guard !isEditable else { super.mouseDown(with: event); return }
        switch event.clickCount {
        case 1: onClick()
        case 2: onDoubleClick(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
        default: break
        }
    }

    override func insertNewline(_ sender: Any?) {
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        if mods.contains(.shift) || mods.contains(.option) { super.insertNewlineIgnoringFieldEditor(sender); return }
        onCommit()
    }

    override func cancelOperation(_ sender: Any?) {
        if isEditable { onCancel() } else { super.cancelOperation(sender) }
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, isEditable { onResign() }
        return ok
    }
}
