import Foundation

/// Word (.docx) export written directly as Office Open XML, so screenplay rules survive in Word:
/// headings and cues keep with what follows, speeches don't split mid-line, side-by-side dialogue is a
/// borderless two-column table, and the page has screenplay margins.
public enum DOCX {
    /// Page size in points (A4 595.28 × 841.89, US Letter 612 × 792).
    public static func document(scripts: [String], titlePage: String?, pageSize: (width: Double, height: Double)) -> Data {
        var body: [String] = []
        if let titlePage {
            let tp = Screenplay.titlePage(titlePage)
            if !tp.isEmpty {
                for (n, l) in tp.centre.enumerated() { body.append(p(l.runs, jc: "center", before: n == 0 ? 5040 : 0)) }
                for (n, l) in tp.bottomLeft.enumerated() { body.append(p(l.runs, before: n == 0 ? 5040 : 0)) }
                body.append(#"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#)
            }
        }
        let els = Screenplay.elements(scripts)
        var breakNext = false
        var i = 0
        func speech(_ start: Int) -> (cue: String, lines: [Screenplay.Element], next: Int) {
            var j = start + 1, lines: [Screenplay.Element] = []
            while j < els.count, els[j].kind == .dialogue || els[j].kind == .parenthetical { lines.append(els[j]); j += 1 }
            return (els[start].text, lines, j)
        }
        while i < els.count {
            let e = els[i]
            let pb = breakNext
            breakNext = false
            switch e.kind {
            case .pageBreak: breakNext = true; i += 1; continue
            case .heading: body.append(p(Screenplay.runs(e.text), before: 480, keepNext: true, bold: true, pageBreak: pb))
            case .action: body.append(p(Screenplay.runs(e.text), before: 240, pageBreak: pb))
            case .transition: body.append(p(Screenplay.runs(e.text), jc: "right", before: 240, pageBreak: pb))
            case .centered: body.append(p(Screenplay.runs(e.text), jc: "center", before: 240, pageBreak: pb))
            case .parenthetical, .dialogue: body.append(p(Screenplay.runs(e.text), left: 1440, right: 2160, pageBreak: pb))
            case .character:
                let first = speech(i)
                if first.next < els.count, els[first.next].kind == .character, els[first.next].dual {
                    let second = speech(first.next)
                    body.append(dualTable(first, second, pageBreak: pb))
                    i = second.next
                    continue
                }
                body.append(p(Screenplay.runs(e.text), left: 3168, before: 240, keepNext: true, pageBreak: pb))
                for (n, l) in first.lines.enumerated() {
                    let last = n == first.lines.count - 1
                    body.append(l.kind == .parenthetical
                        ? p(Screenplay.runs(l.text), left: 2304, right: 2736, keepNext: true)
                        : p(Screenplay.runs(l.text), left: 1440, right: 2160, keepNext: !last && first.lines[n + 1].kind == .parenthetical))
                }
                i = first.next
                continue
            }
            i += 1
        }
        let w = Int(pageSize.width * 20), h = Int(pageSize.height * 20)
        body.append(#"<w:sectPr><w:pgSz w:w="\#(w)" w:h="\#(h)"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="2160" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>"#)
        let document = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"#
            + body.joined() + "</w:body></w:document>"
        return Zip.archive([
            ("[Content_Types].xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>"#),
            ("_rels/.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#),
            ("word/_rels/document.xml.rels", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#),
            ("word/styles.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Courier Prime" w:hAnsi="Courier Prime" w:cs="Courier Prime"/><w:sz w:val="24"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="exact"/></w:pPr></w:pPrDefault></w:docDefaults></w:styles>"#),
            ("word/document.xml", document),
        ].map { ($0.0, Data($0.1.utf8)) })
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func runs(_ runs: [Screenplay.Run], bold: Bool = false) -> String {
        runs.map { r in
            let props = (r.bold || bold ? "<w:b/>" : "") + (r.italic ? "<w:i/>" : "") + (r.underline ? #"<w:u w:val="single"/>"# : "")
            let parts = r.text.components(separatedBy: "\n").map { #"<w:t xml:space="preserve">\#(esc($0))</w:t>"# }
            return "<w:r>" + (props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>") + parts.joined(separator: "<w:br/>") + "</w:r>"
        }.joined()
    }

    /// A paragraph. Indents and spacing in twips (1/20 pt; one Courier character is 144).
    static func p(_ rs: [Screenplay.Run], left: Int = 0, right: Int = 0, jc: String? = nil, before: Int = 0,
                  keepNext: Bool = false, bold: Bool = false, pageBreak: Bool = false) -> String {
        var ppr = ""
        if pageBreak { ppr += "<w:pageBreakBefore/>" }
        if keepNext { ppr += "<w:keepNext/>" }
        ppr += "<w:keepLines/>"
        if before > 0 { ppr += #"<w:spacing w:before="\#(before)"/>"# }
        if left > 0 || right > 0 { ppr += #"<w:ind w:left="\#(left)" w:right="\#(right)"/>"# }
        if let jc { ppr += #"<w:jc w:val="\#(jc)"/>"# }
        return "<w:p><w:pPr>\(ppr)</w:pPr>\(runs(rs, bold: bold))</w:p>"
    }

    static func dualTable(_ a: (cue: String, lines: [Screenplay.Element], next: Int),
                          _ b: (cue: String, lines: [Screenplay.Element], next: Int), pageBreak: Bool) -> String {
        func cell(_ s: (cue: String, lines: [Screenplay.Element], next: Int)) -> String {
            var ps = [p(Screenplay.runs(s.cue), jc: "center", keepNext: true)]
            ps += s.lines.map { $0.kind == .parenthetical ? p(Screenplay.runs($0.text), left: 432, keepNext: true) : p(Screenplay.runs($0.text)) }
            return #"<w:tc><w:tcPr><w:tcW w:w="4320" w:type="dxa"/></w:tcPr>"# + ps.joined() + "</w:tc>"
        }
        let none = #"<w:top w:val="nil"/><w:left w:val="nil"/><w:bottom w:val="nil"/><w:right w:val="nil"/><w:insideH w:val="nil"/><w:insideV w:val="nil"/>"#
        return (pageBreak ? #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"# : #"<w:p><w:pPr><w:keepNext/></w:pPr></w:p>"#)
            + #"<w:tbl><w:tblPr><w:tblW w:w="8640" w:type="dxa"/><w:tblBorders>\#(none)</w:tblBorders><w:tblLayout w:type="fixed"/></w:tblPr><w:tblGrid><w:gridCol w:w="4320"/><w:gridCol w:w="4320"/></w:tblGrid><w:tr><w:trPr><w:cantSplit/></w:trPr>"#
            + cell(a) + cell(b) + "</w:tr></w:tbl>"
    }
}

/// A minimal ZIP writer (stored, no compression), enough for .docx packages.
public enum Zip {
    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }

    public static func archive(_ files: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        for (name, data) in files {
            let n = Data(name.utf8), crc = crc32(data), size = UInt32(data.count), offset = UInt32(out.count)
            // Local header: signature, version, flags (UTF-8 names), method 0 (stored), time/date, crc, sizes, name.
            let local: [Data] = [le32(0x0403_4b50), le16(20), le16(0x0800), le16(0), le16(0), le16(0x21), le32(crc), le32(size), le32(size),
                                 le16(n.count), le16(0), n, data]
            local.forEach { out.append($0) }
            let entry: [Data] = [le32(0x0201_4b50), le16(20), le16(20), le16(0x0800), le16(0), le16(0), le16(0x21), le32(crc),
                                 le32(size), le32(size), le16(n.count), le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), n]
            entry.forEach { central.append($0) }
        }
        let start = UInt32(out.count)
        out += central
        let end: [Data] = [le32(0x0605_4b50), le16(0), le16(0), le16(files.count), le16(files.count), le32(UInt32(central.count)), le32(start), le16(0)]
        end.forEach { out.append($0) }
        return out
    }
}
