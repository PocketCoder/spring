import AppKit
import SpringCore
import SwiftUI

enum Theme {
    static let paper = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1) : NSColor(srgbRed: 0.984, green: 0.984, blue: 0.98, alpha: 1) }
    static let accent = NSColor(srgbRed: 0.184, green: 0.365, blue: 0.541, alpha: 1)

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
        for (line, kind) in zip(Fountain.lines(text), Fountain.classify(text)) {
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
    var onEndEditing: () -> Void = {}
    var onBury: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let tv = SceneTextView(usingTextLayoutManager: false)
        tv.onBury = { [weak coordinator = context.coordinator] in coordinator?.parent.onBury($0) }
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
            tv.string = text
            context.coordinator.restyle(tv)
        } else if sizeChanged {
            context.coordinator.restyle(tv)
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

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            restyle(tv)
            parent.text = tv.string
        }

        func textDidEndEditing(_ notification: Notification) { parent.onEndEditing() }

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
    var onBury: ((String) -> Void)?

    @objc func sendToGraveyard(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let text = (string as NSString?)?.substring(with: range) else { return }
        if shouldChangeText(in: range, replacementString: "") {
            textStorage?.replaceCharacters(in: range, with: "")
            didChangeText()
        }
        onBury?(text)
    }
}
