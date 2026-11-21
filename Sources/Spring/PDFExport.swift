import AppKit
import SpringCore
import SwiftUI

/// Draws `Screenplay` pages into a PDF: Courier Prime 12 pt, 1.5" left margin, 1" top, page numbers top right
/// from page 2, optional scene numbers in both margins.
enum PDFExport {
    enum Paper: String, CaseIterable, Identifiable {
        case a4 = "A4", letter = "US Letter"
        var id: String { rawValue }
        var size: CGSize { self == .a4 ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 612, height: 792) }
        /// 6 lines an inch inside 1" top and bottom margins.
        var linesPerPage: Int { Int((size.height - 144) / 12) }
    }

    static let left: CGFloat = 108, top: CGFloat = 72, lineHeight: CGFloat = 12, fontSize: CGFloat = 12

    static func font(bold: Bool, italic: Bool) -> NSFont {
        var f = NSFont(name: "Courier Prime", size: fontSize) ?? NSFont(name: "Courier New", size: fontSize)!
        if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    static func string(_ runs: [Screenplay.Run]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for r in runs {
            var attrs: [NSAttributedString.Key: Any] = [.font: font(bold: r.bold, italic: r.italic), .foregroundColor: NSColor.black]
            if r.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: r.text, attributes: attrs))
        }
        return out
    }

    static func render(scripts: [String], titlePage: String?, paper: Paper, sceneNumbers: Bool) -> Data {
        let pages = Screenplay.paginate(scripts, options: .init(linesPerPage: paper.linesPerPage, sceneNumbers: sceneNumbers))
        let title = titlePage.map(Screenplay.titlePage)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: paper.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let charWidth = ("M" as NSString).size(withAttributes: [.font: font(bold: false, italic: false)]).width
        let textWidth = 60 * charWidth
        let size = paper.size

        func draw(_ line: Screenplay.Line, row: Int) {
            let s = string(line.runs)
            let y = size.height - top - CGFloat(row + 1) * lineHeight
            let w = s.size().width
            let x: CGFloat
            switch line.align {
            case .left: x = left + CGFloat(line.indent) * charWidth
            case .center: x = left + (textWidth - w) / 2
            case .right: x = left + textWidth - w
            }
            s.draw(at: CGPoint(x: x, y: y))
            if !line.right.isEmpty {
                string(line.right).draw(at: CGPoint(x: left + CGFloat(line.rightIndent) * charWidth, y: y))
            }
            if let n = line.sceneNumber {
                let num = NSAttributedString(string: n, attributes: [.font: font(bold: true, italic: false), .foregroundColor: NSColor.black])
                num.draw(at: CGPoint(x: left - 0.75 * 72, y: y))
                num.draw(at: CGPoint(x: left + textWidth + 0.35 * 72, y: y))
            }
        }

        func page(_ body: () -> Void) {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            body()
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }

        if let title, !title.isEmpty {
            page {
                let startRow = paper.linesPerPage / 3
                for (i, l) in title.centre.enumerated() { draw(l, row: startRow + i) }
                let bottomStart = paper.linesPerPage - title.bottomLeft.count
                for (i, l) in title.bottomLeft.enumerated() { draw(l, row: bottomStart + i) }
            }
        }
        for (n, lines) in pages.enumerated() {
            page {
                if n > 0 {
                    let num = NSAttributedString(string: "\(n + 1).", attributes: [.font: font(bold: false, italic: false), .foregroundColor: NSColor.black])
                    num.draw(at: CGPoint(x: left + textWidth - num.size().width, y: size.height - 36 - lineHeight))
                }
                for (row, line) in lines.enumerated() { if let line { draw(line, row: row) } }
            }
        }
        ctx.closePDF()
        return data as Data
    }
}

/// Options shown under the save panel.
struct PDFExportOptions: View {
    @AppStorage("pdfPaper") var paper = PDFExport.Paper.a4.rawValue
    @AppStorage("pdfTitlePage") var titlePage = true
    @AppStorage("pdfSceneNumbers") var sceneNumbers = false

    var body: some View {
        HStack(spacing: 20) {
            Picker("Paper:", selection: $paper) {
                ForEach(PDFExport.Paper.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .fixedSize()
            Toggle("Title page", isOn: $titlePage)
            Toggle("Scene numbers", isOn: $sceneNumbers)
        }
        .padding(12)
    }
}

extension ProjectModel {
    func exportPDF() {
        guard let root = projectURL else { return }
        saveAll()
        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = root.lastPathComponent + ".pdf"
        let exports = root.appending(path: "Exports")
        try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        panel.directoryURL = exports
        let accessory = NSHostingView(rootView: PDFExportOptions())
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let d = UserDefaults.standard
        let paper = PDFExport.Paper(rawValue: d.string(forKey: "pdfPaper") ?? "") ?? .a4
        let withTitle = d.object(forKey: "pdfTitlePage") == nil || d.bool(forKey: "pdfTitlePage")
        let title = withTitle ? try? String(contentsOf: root.appending(path: "front-matter.md"), encoding: .utf8) : nil
        let data = PDFExport.render(scripts: scenes.map(\.file.body), titlePage: title, paper: paper,
                                    sceneNumbers: d.bool(forKey: "pdfSceneNumbers"))
        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = "Couldn't write the PDF: \(error.localizedDescription)"
        }
    }

    /// The whole script as one Fountain file (title page first), for other Fountain apps or plain text.
    func exportFountain() {
        guard let root = projectURL else { return }
        saveAll()
        let panel = NSSavePanel()
        panel.title = "Export Fountain"
        panel.nameFieldStringValue = root.lastPathComponent + ".fountain"
        let exports = root.appending(path: "Exports")
        try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        panel.directoryURL = exports
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let title = (try? String(contentsOf: root.appending(path: "front-matter.md"), encoding: .utf8)).map { MarkdownFile(text: $0).body } ?? ""
        let body = scenes.map { $0.file.body.trimmingCharacters(in: .newlines) }.joined(separator: "\n\n")
        let text = (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : title.trimmingCharacters(in: .newlines) + "\n\n") + body + "\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
            errorMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

/// Word (.docx) export: one styled paragraph per element with screenplay indents and page margins, so Word reflows it.
enum DOCXExport {
    static func document(scripts: [String], titlePage: String?, paper: PDFExport.Paper) -> Data? {
        let cw: CGFloat = 7.2 // Courier 12 pt advance
        let out = NSMutableAttributedString()
        func para(_ text: String, head: CGFloat = 0, tail: CGFloat = 0, align: NSTextAlignment = .left, before: CGFloat = 12,
                  bold: Bool = false, pageBreakBefore: Bool = false) {
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = head * cw
            p.headIndent = head * cw
            if tail > 0 { p.tailIndent = -(60 - tail) * cw } // negative: measured from the right margin, which Word keeps
            p.alignment = align
            p.paragraphSpacingBefore = before
            if pageBreakBefore, out.length > 0 { out.append(NSAttributedString(string: "\u{0C}")) }
            let line = NSMutableAttributedString()
            for r in Screenplay.runs(text) {
                var attrs: [NSAttributedString.Key: Any] = [.font: PDFExport.font(bold: r.bold || bold, italic: r.italic), .paragraphStyle: p]
                if r.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                line.append(NSAttributedString(string: r.text.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: attrs))
            }
            if line.length == 0 { line.append(NSAttributedString(string: "", attributes: [.font: PDFExport.font(bold: false, italic: false), .paragraphStyle: p])) }
            line.append(NSAttributedString(string: "\n", attributes: [.font: PDFExport.font(bold: false, italic: false), .paragraphStyle: p]))
            out.append(line)
        }
        if let titlePage {
            let tp = Screenplay.titlePage(titlePage)
            if !tp.isEmpty {
                for (n, l) in tp.centre.enumerated() { para(l.text, align: .center, before: n == 0 ? 216 : 0, bold: n == 0) }
                for (n, l) in tp.bottomLeft.enumerated() { para(l.text, before: n == 0 ? 216 : 0) }
            }
        }
        var breakNext = out.length > 0
        for e in Screenplay.elements(scripts) {
            let pb = breakNext
            switch e.kind {
            case .pageBreak: breakNext = true; continue
            case .heading: para(e.text, before: 24, bold: true, pageBreakBefore: pb)
            case .action: para(e.text, pageBreakBefore: pb)
            case .character: para(e.text, head: 22, pageBreakBefore: pb)
            case .parenthetical: para(e.text, head: 16, tail: 41, before: 0, pageBreakBefore: pb)
            case .dialogue: para(e.text, head: 10, tail: 45, before: 0, pageBreakBefore: pb)
            case .transition: para(e.text, align: .right, pageBreakBefore: pb)
            case .centered: para(e.text, align: .center, pageBreakBefore: pb)
            }
            breakNext = false
        }
        let attrs: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML,
            .paperSize: paper.size, .leftMargin: 108.0, .rightMargin: 72.0, .topMargin: 72.0, .bottomMargin: 72.0,
        ]
        return try? out.data(from: NSRange(location: 0, length: out.length), documentAttributes: attrs)
    }
}

extension ProjectModel {
    /// Word or Final Draft export of the whole script.
    func export(as ext: String) {
        guard let root = projectURL else { return }
        saveAll()
        let panel = NSSavePanel()
        panel.title = ext == "fdx" ? "Export Final Draft" : "Export Word Document"
        panel.nameFieldStringValue = root.lastPathComponent + "." + ext
        let exports = root.appending(path: "Exports")
        try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        panel.directoryURL = exports
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let title = try? String(contentsOf: root.appending(path: "front-matter.md"), encoding: .utf8)
        let scripts = scenes.map(\.file.body)
        let paper = PDFExport.Paper(rawValue: UserDefaults.standard.string(forKey: "pdfPaper") ?? "") ?? .a4
        let data = ext == "fdx" ? Data(FDX.document(scripts: scripts, titlePage: title).utf8)
                                : DOCXExport.document(scripts: scripts, titlePage: title, paper: paper)
        do {
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }
}
