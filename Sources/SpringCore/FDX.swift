import Foundation

/// Final Draft (.fdx) export: one Paragraph per element, emphasis as Text styles,
/// `^` speeches wrapped in DualDialogue, scene numbers on headings, and the title page.
public enum FDX {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func texts(_ text: String) -> String {
        Screenplay.runs(text).map { r in
            let style = [r.bold ? "Bold" : nil, r.italic ? "Italic" : nil, r.underline ? "Underline" : nil].compactMap { $0 }.joined(separator: "+")
            return style.isEmpty ? "<Text>\(escape(r.text))</Text>" : "<Text Style=\"\(style)\">\(escape(r.text))</Text>"
        }.joined()
    }

    static func paragraph(_ type: String, _ text: String, extra: String = "") -> String {
        "    <Paragraph Type=\"\(type)\"\(extra)>\(texts(text))</Paragraph>"
    }

    public static func document(scripts: [String], titlePage: String?) -> String {
        let types: [Screenplay.ElementKind: String] = [
            .heading: "Scene Heading", .action: "Action", .character: "Character",
            .parenthetical: "Parenthetical", .dialogue: "Dialogue", .transition: "Transition", .centered: "Action",
        ]
        var out: [String] = []
        var newPage = false
        let els = Screenplay.elements(scripts)
        var i = 0
        // A speech: its cue and the lines after it, as paragraphs.
        func speech(from start: Int) -> (paras: [String], next: Int) {
            var paras = [paragraph("Character", els[start].text)]
            var j = start + 1
            while j < els.count, els[j].kind == .dialogue || els[j].kind == .parenthetical {
                paras.append(paragraph(types[els[j].kind]!, els[j].text)); j += 1
            }
            return (paras, j)
        }
        while i < els.count {
            let e = els[i]
            var extra = newPage ? " StartsNewPage=\"Yes\"" : ""
            switch e.kind {
            case .pageBreak:
                newPage = true; i += 1; continue
            case .character:
                let first = speech(from: i)
                if first.next < els.count, els[first.next].kind == .character, els[first.next].dual {
                    let second = speech(from: first.next)
                    out.append("    <Paragraph\(extra)>\n      <DualDialogue>\n" + (first.paras + second.paras).map { "  " + $0 }.joined(separator: "\n") + "\n      </DualDialogue>\n    </Paragraph>")
                    i = second.next
                } else {
                    if newPage, var p = first.paras.first { p = p.replacingOccurrences(of: "Type=\"Character\"", with: "Type=\"Character\"" + extra); out.append(p); out += first.paras.dropFirst() }
                    else { out += first.paras }
                    i = first.next
                }
            default:
                if e.kind == .heading, let n = e.sceneNumber { extra += " Number=\"\(escape(n))\"" }
                if e.kind == .centered { extra += " Alignment=\"Center\"" }
                out.append(paragraph(types[e.kind]!, e.text, extra: extra))
                i += 1
            }
            newPage = false
        }
        var title: [String] = []
        if let titlePage {
            let tp = Screenplay.titlePage(titlePage)
            let centre = tp.centre.map { $0.text.isEmpty ? "    <Paragraph Alignment=\"Center\"><Text></Text></Paragraph>" : "    <Paragraph Alignment=\"Center\"><Text>\(escape($0.text))</Text></Paragraph>" }
            let left = tp.bottomLeft.map { "    <Paragraph Alignment=\"Left\"><Text>\(escape($0.text))</Text></Paragraph>" }
            if !tp.isEmpty {
                title = ["  <TitlePage>", "   <Content>"] + Array(repeating: "    <Paragraph><Text></Text></Paragraph>", count: 16) + centre
                    + Array(repeating: "    <Paragraph><Text></Text></Paragraph>", count: 18) + left + ["   </Content>", "  </TitlePage>"]
            }
        }
        return (["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\" ?>",
                 "<FinalDraft DocumentType=\"Script\" Template=\"No\" Version=\"5\">",
                 "  <Content>"] + out + ["  </Content>"] + title + ["</FinalDraft>", ""]).joined(separator: "\n")
    }
}
