import AppKit
import SpringCore
import SwiftUI

enum Theme {
    static let paper = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1) : NSColor(srgbRed: 0.984, green: 0.984, blue: 0.98, alpha: 1) }
    static let accents: [(name: String, color: NSColor)] = [
        ("Ink blue", NSColor(srgbRed: 0.184, green: 0.365, blue: 0.541, alpha: 1)),
        ("Brick", NSColor(srgbRed: 0.706, green: 0.329, blue: 0.227, alpha: 1)),
        ("Fern", NSColor(srgbRed: 0.247, green: 0.490, blue: 0.345, alpha: 1)),
        ("Violet", NSColor(srgbRed: 0.420, green: 0.357, blue: 0.659, alpha: 1)),
        ("Graphite", NSColor(srgbRed: 0.29, green: 0.286, blue: 0.271, alpha: 1)),
    ]
    static var accent: NSColor {
        let name = UserDefaults.standard.string(forKey: "accentColour") ?? ""
        return accents.first { $0.name == name }?.color ?? accents[0].color
    }
    /// Binder, corkboard and welcome side panels: a shade darker than the page.
    static let paper2 = dynamic(light: (0.957, 0.953, 0.941), dark: (0.137, 0.137, 0.145))
    /// Hairlines and card borders.
    static let line = dynamic(light: (0.902, 0.894, 0.875), dark: (0.18, 0.18, 0.192))

    static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) {
            let c = $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    /// The chosen font (bundled Courier Prime by default), else Courier New.
    static func scriptFont(_ name: String, _ size: CGFloat) -> NSFont {
        NSFont(name: name, size: size) ?? NSFont(name: "Courier New", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Applies Fountain screenplay layout to a scene's text. Indents follow the standard
/// 60-character page: cue at 22, dialogue 10–45, parenthetical 16–41.
enum ScriptStyler {
    static func apply(to storage: NSTextStorage, fontName: String, fontSize: CGFloat) {
        let text = storage.string
        let base = Theme.scriptFont(fontName, fontSize)
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        let cw = ("M" as NSString).size(withAttributes: [.font: base]).width
        let total = (text as NSString).length
        var loc = 0
        storage.beginEditing()
        // ponytail: restyles the whole scene per keystroke; fine for scene-sized files, go incremental if a scene ever gets long.
        let kinds = Fountain.classify(text)
        // Dual dialogue: the two speeches become the two cells of a one-row text table, side by side.
        var cells: [Int: NSTextTableBlock] = [:]
        for pair in Fountain.dualPairs(text, kinds: kinds) {
            let table = NSTextTable()
            table.numberOfColumns = 2
            table.layoutAlgorithm = .fixedLayoutAlgorithm
            for (column, lines) in [pair.left, pair.right].enumerated() {
                let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setContentWidth(50, type: .percentageValueType)
                cell.setWidth(column == 0 ? 2 * cw : 0, type: .absoluteValueType, for: .padding, edge: .maxX)
                for l in lines { cells[l] = cell }
            }
        }
        for (n, (line, kind)) in zip(Fountain.lines(text), kinds).enumerated() {
            let len = line.utf16.count
            let range = NSRange(location: loc, length: min(len + 1, total - loc))
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.2
            var font = base
            var colour = NSColor.textColor
            func indent(_ head: CGFloat, _ tail: CGFloat? = nil) {
                p.firstLineHeadIndent = head * cw
                p.headIndent = head * cw
                if let tail { p.tailIndent = tail * cw }
            }
            switch kind {
            case .heading: font = bold
            case .character: indent(22)
            case .dialogue: indent(10, 45)
            case .parenthetical: indent(16, 41)
            case .transition: p.alignment = .right
            case .centered: p.alignment = .center
            case .section, .synopsis, .note, .pageBreak: colour = .secondaryLabelColor
            default: break
            }
            if let cell = cells[n] {
                p.textBlocks = [cell]
                p.firstLineHeadIndent = kind == .parenthetical ? 3 * cw : 0
                p.headIndent = p.firstLineHeadIndent
                p.tailIndent = 0
                p.alignment = kind == .character ? .center : .natural
                if kind == .blank { // the blank line between the speeches sits in the left cell: keep it from adding height
                    p.maximumLineHeight = 1
                    font = Theme.scriptFont(fontName, 1)
                }
            }
            if range.length > 0 {
                storage.setAttributes([.font: font, .paragraphStyle: p, .foregroundColor: colour], range: range)
            }
            loc += len + 1
        }
        storage.endEditing()
    }
}

/// One scene's editor. Grows to fit its text so scenes stack into one continuous script.
struct ScriptTextView: NSViewRepresentable {
    @Binding var text: String
    var fontName: String
    var fontSize: CGFloat
    var sceneID = UUID()
    var onEndEditing: () -> Void = {}
    var onBeginEditing: () -> Void = {}
    /// Hands cut text to the Graveyard; returns how to take it back out (registered with the same undo).
    var onBury: (String) -> (() -> Void) = { _ in {} }
    /// Arrow up off the first line (true) or down off the last (false). Returns true when another scene took focus.
    var onLeave: (Bool) -> Bool = { _ in false }
    var focusRequest: ProjectModel.FocusRequest?
    var typewriter = false
    var dim = false
    /// Whole-line suggestions for (text before the cursor on this line, previous line is blank).
    var suggest: (String, Bool) -> [String] = { _, _ in [] }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let tv = SceneTextView(usingTextLayoutManager: false)
        tv.onBury = { [weak coordinator = context.coordinator] in coordinator?.parent.onBury($0) ?? {} }
        tv.onLeave = { [weak coordinator = context.coordinator] in coordinator?.parent.onLeave($0) ?? false }
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.insertionPointColor = Theme.accent
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator
        tv.string = text
        context.coordinator.restyle(tv)
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        let old = context.coordinator.parent
        let sizeChanged = old.fontSize != fontSize || old.fontName != fontName
        context.coordinator.parent = self
        if tv.string != text {
            // Text changed outside Spring: keep the cursor where it was (clamped), not at the end.
            let sel = tv.selectedRange()
            tv.string = text
            let len = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
            context.coordinator.restyle(tv)
        } else if sizeChanged {
            context.coordinator.restyle(tv)
        }
        tv.insertionPointColor = Theme.accent
        if old.dim != dim { context.coordinator.applyDim(tv) }
        // Focus handed over from the scene above or below (arrow keys), or from the scene list.
        if let r = focusRequest, r.id == sceneID, r.token != context.coordinator.handledFocus {
            context.coordinator.handledFocus = r.token
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
                let len = (tv.string as NSString).length
                tv.setSelectedRange(NSRange(location: r.atEnd ? len : 0, length: 0))
                tv.scrollRangeToVisible(tv.selectedRange())
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView, context: Context) -> CGSize? {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let width = proposal.width ?? 600
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let lineHeight = lm.defaultLineHeight(for: Theme.scriptFont(fontName, fontSize))
        return CGSize(width: width, height: max(lm.usedRect(for: tc).height, lineHeight))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptTextView
        init(_ parent: ScriptTextView) { self.parent = parent }

        var handledFocus = -1
        private var completing = false
        private var typedCharacter = false

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            restyle(tv)
            parent.text = tv.string
            // Offer cue and heading completions while typing (not when deleting or after a completion).
            if typedCharacter, !completing, !suggestions(tv).isEmpty {
                completing = true
                tv.complete(nil)
                completing = false
            }
            typedCharacter = false
        }

        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            typedCharacter = !completing && (replacementString.map { $0.count == 1 && $0 != "\n" } ?? false)
            return true
        }

        func textView(_ tv: NSTextView, completions words: [String], forPartialWordRange range: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            index?.pointee = 0
            return suggestions(tv)
        }

        /// Text from the start of the cursor's line, and whether the line above is blank.
        private func suggestions(_ tv: NSTextView) -> [String] {
            let ns = tv.string as NSString
            let cursor = tv.selectedRange().location
            guard cursor <= ns.length else { return [] }
            let lineStart = ns.lineRange(for: NSRange(location: cursor, length: 0)).location
            let line = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
            var afterBlank = true
            if lineStart > 0 {
                let prev = ns.lineRange(for: NSRange(location: lineStart - 1, length: 0))
                afterBlank = ns.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return parent.suggest(line, afterBlank)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEndEditing()
            if let tv = notification.object as? NSTextView { clearDim(tv) }
        }
        func textDidBeginEditing(_ notification: Notification) { parent.onBeginEditing() }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? SceneTextView, tv.window?.firstResponder === tv else { return }
            applyDim(tv)
            if parent.typewriter { centreCaret(tv) }
        }

        /// Typewriter scrolling: keep the line being written in the middle of the window.
        func centreCaret(_ tv: SceneTextView) {
            guard let sv = tv.enclosingScrollView, let line = tv.caretLineRect() else { return }
            let r = tv.convert(line, to: sv.contentView)
            var origin = sv.contentView.bounds.origin
            origin.y += r.midY - sv.contentView.bounds.midY
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                sv.contentView.animator().setBoundsOrigin(origin)
            }
            sv.reflectScrolledClipView(sv.contentView)
        }

        /// Focus mode: everything but the paragraph being written fades back (display only, the text is untouched).
        func applyDim(_ tv: NSTextView) {
            guard let lm = tv.layoutManager else { return }
            let ns = tv.string as NSString
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: ns.length))
            guard parent.dim, tv.window?.firstResponder === tv, ns.length > 0 else { return }
            let here = ns.paragraphRange(for: NSRange(location: min(tv.selectedRange().location, ns.length), length: 0))
            lm.addTemporaryAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, forCharacterRange: NSRange(location: 0, length: here.location))
            let after = here.location + here.length
            lm.addTemporaryAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, forCharacterRange: NSRange(location: after, length: ns.length - after))
        }

        func clearDim(_ tv: NSTextView) {
            tv.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard view.selectedRange().length > 0 else { return menu }
            let item = NSMenuItem(title: "Send to Graveyard", action: #selector(SceneTextView.sendToGraveyard(_:)), keyEquivalent: "")
            item.target = view
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        func restyle(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            ScriptStyler.apply(to: storage, fontName: parent.fontName, fontSize: parent.fontSize)
            tv.typingAttributes = [.font: Theme.scriptFont(parent.fontName, parent.fontSize), .foregroundColor: NSColor.textColor]
        }
    }
}

/// A scene's text view. "Send to Graveyard" (context menu, or Edit menu ⇧⌘G via the responder chain)
/// cuts the selection, undoably, and hands it to the Graveyard.
final class SceneTextView: NSTextView {
    var onBury: ((String) -> (() -> Void))?
    var onLeave: ((Bool) -> Bool)?

    /// The line fragment the caret is on, in text view coordinates.
    func caretLineRect() -> NSRect? {
        guard let lm = layoutManager else { return nil }
        let len = (string as NSString).length
        let loc = selectedRange().location
        if loc >= len, !lm.extraLineFragmentRect.isEmpty { return lm.extraLineFragmentRect }
        guard lm.numberOfGlyphs > 0 else { return .zero }
        return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: min(loc, len - 1)), effectiveRange: nil)
    }

    // Arrow keys carry on into the scene above or below, so the stacked scenes read as one script.
    override func moveUp(_ sender: Any?) {
        if let r = caretLineRect(), r.minY <= 0.5, onLeave?(true) == true { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if let r = caretLineRect(), let lm = layoutManager, let tc = textContainer,
           r.maxY >= lm.usedRect(for: tc).maxY - 0.5, onLeave?(false) == true { return }
        super.moveDown(sender)
    }

    /// Completions replace the whole line typed so far ("INT. HO" → "INT. HOUSE"), not just the last word.
    override var rangeForUserCompletion: NSRange {
        let cursor = selectedRange().location
        let start = (string as NSString).lineRange(for: NSRange(location: cursor, length: 0)).location
        return NSRange(location: start, length: cursor - start)
    }

    @objc func sendToGraveyard(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let text = (string as NSString?)?.substring(with: range) else { return }
        // One undo step: puts the text back and takes it out of the Graveyard file again.
        undoManager?.beginUndoGrouping()
        if shouldChangeText(in: range, replacementString: "") {
            textStorage?.replaceCharacters(in: range, with: "")
            didChangeText()
        }
        if let restore = onBury?(text) { undoManager?.registerUndo(withTarget: self) { _ in restore() } }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Send to Graveyard")
    }
}
