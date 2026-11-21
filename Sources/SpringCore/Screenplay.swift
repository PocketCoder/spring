import Foundation

/// Lays a Fountain script out as screenplay pages: standard indents on a 60-character line, Courier 12 pt at
/// 6 lines an inch, headings kept with what follows, and dialogue split across pages with (MORE) and (CONT'D).
/// Pure text layout; the PDF renderer only draws what this produces.
public enum Screenplay {
    // MARK: Model

    public struct Run: Equatable, Sendable {
        public var text: String
        public var bold = false, italic = false, underline = false
        public init(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false) {
            self.text = text; self.bold = bold; self.italic = italic; self.underline = underline
        }
    }

    public enum Align: Sendable { case left, center, right }

    public struct Line: Equatable, Sendable {
        public var runs: [Run]
        /// Characters from the left margin.
        public var indent: Int = 0
        public var align: Align = .left
        /// Printed in the margins beside a scene heading when scene numbers are on.
        public var sceneNumber: String?
        /// Dual dialogue: the second speaker's column on the same row.
        public var right: [Run] = []
        public var rightIndent: Int = 0
        public var text: String { runs.map(\.text).joined() }
        public var rightText: String { right.map(\.text).joined() }
    }

    /// nil is a blank line.
    public typealias Page = [Line?]

    public struct Options: Sendable {
        public var linesPerPage: Int
        public var sceneNumbers: Bool
        public init(linesPerPage: Int = 54, sceneNumbers: Bool = false) {
            self.linesPerPage = linesPerPage; self.sceneNumbers = sceneNumbers
        }
    }

    // Standard layout on a 60-character line (1.5" left margin, Courier 10 cpi).
    static let actionWidth = 60
    static let cueIndent = 22, dialogueIndent = 10, dialogueWidth = 35, parenIndent = 16, parenWidth = 26

    // MARK: Emphasis

    /// Fountain emphasis: ***bold italic***, **bold**, *italic*, _underline_; `\*` and `\_` are literal.
    public static func runs(_ text: String) -> [Run] {
        var out: [Run] = []
        var bold = false, italic = false, underline = false
        var buf = ""
        func flush() { if !buf.isEmpty { out.append(Run(buf, bold: bold, italic: italic, underline: underline)); buf = "" } }
        var chars = Array(text)[...]
        while let c = chars.first {
            if c == "\\", chars.count > 1, ["*", "_"].contains(chars[chars.startIndex + 1]) {
                buf.append(chars[chars.startIndex + 1]); chars = chars.dropFirst(2); continue
            }
            if c == "*" {
                let n = chars.prefix(3).prefix { $0 == "*" }.count
                flush()
                if n == 3 { bold.toggle(); italic.toggle() } else if n == 2 { bold.toggle() } else { italic.toggle() }
                chars = chars.dropFirst(n); continue
            }
            if c == "_" { flush(); underline.toggle(); chars = chars.dropFirst(); continue }
            buf.append(c); chars = chars.dropFirst()
        }
        flush()
        return out
    }

    // MARK: Wrapping

    /// Greedy word wrap on visible characters, keeping each word's styles. Over-long words are broken.
    public static func wrap(_ runs: [Run], width: Int) -> [[Run]] {
        typealias Ch = (c: Character, r: Run)
        let chars: [Ch] = runs.flatMap { r in r.text.map { (c: $0, r: r) } }
        var words: [[Ch]] = [], current: [Ch] = []
        for ch in chars {
            if ch.c == " " { if !current.isEmpty { words.append(current); current = [] } } else { current.append(ch) }
        }
        if !current.isEmpty { words.append(current) }
        var lines: [[Ch]] = [], line: [Ch] = []
        for var w in words {
            while w.count > width {
                if !line.isEmpty { lines.append(line); line = [] }
                lines.append(Array(w.prefix(width))); w = Array(w.dropFirst(width))
            }
            if line.isEmpty { line = w }
            else if line.count + 1 + w.count <= width { line.append((c: " ", r: w[0].r)); line += w }
            else { lines.append(line); line = w }
        }
        if !line.isEmpty || lines.isEmpty { lines.append(line) }
        return lines.map { chs in
            var out: [Run] = []
            for ch in chs {
                if let last = out.last, last.bold == ch.r.bold, last.italic == ch.r.italic, last.underline == ch.r.underline {
                    out[out.count - 1].text.append(ch.c)
                } else {
                    out.append(Run(String(ch.c), bold: ch.r.bold, italic: ch.r.italic, underline: ch.r.underline))
                }
            }
            return out
        }
    }

    // MARK: Blocks

    enum Kind { case heading, action, dialogue, dual, transition, centered, pageBreak }

    struct Block {
        var kind: Kind
        var lines: [Line]
        var spaceBefore: Int
        /// Index of the cue line for dialogue blocks (always 0), used for (CONT'D).
        var cue: String?
        /// Dialogue source, kept so a following ^ speech can lay both out side by side.
        var speech: [(paren: Bool, text: String)] = []
    }

    /// Strips what never prints: [[notes]], /* boneyard */, sections and synopses are dropped by kind.
    static func printable(_ text: String) -> String {
        var t = text
        while let r = t.range(of: #"/\*[\s\S]*?\*/"#, options: .regularExpression) { t.removeSubrange(r) }
        while let r = t.range(of: #"\[\[[\s\S]*?\]\]"#, options: .regularExpression) { t.removeSubrange(r) }
        return t
    }

    // MARK: Elements (shared by PDF, DOCX and FDX export)

    public enum ElementKind: Sendable { case heading, action, character, parenthetical, dialogue, transition, centered, pageBreak }

    /// One printable paragraph. `text` keeps Fountain emphasis marks; action lines are joined with "\n".
    public struct Element: Equatable, Sendable {
        public var kind: ElementKind
        public var text: String
        /// Headings: "4", or as written ("#4A#" gives "4A").
        public var sceneNumber: String?
        /// Characters: this speech sits beside the one before it (`^`).
        public var dual = false
    }

    public static func elements(_ scripts: [String]) -> [Element] {
        var out: [Element] = []
        var sceneNumber = 0
        for script in scripts {
            let text = printable(script)
            let lines = Fountain.lines(text)
            let kinds = Fountain.classify(text)
            var i = 0
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                switch kinds[i] {
                case .blank, .section, .synopsis, .note:
                    break
                case .pageBreak:
                    out.append(Element(kind: .pageBreak, text: ""))
                case .heading:
                    sceneNumber += 1
                    var heading = t.hasPrefix(".") ? String(t.dropFirst()) : t
                    var number = "\(sceneNumber)"
                    if let r = heading.range(of: #"\s*#[^#]*#\s*$"#, options: .regularExpression) {
                        number = heading[r].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                        heading.removeSubrange(r)
                    }
                    out.append(Element(kind: .heading, text: heading.uppercased(), sceneNumber: number))
                case .transition:
                    out.append(Element(kind: .transition, text: (t.hasPrefix(">") ? String(t.dropFirst()).trimmingCharacters(in: .whitespaces) : t).uppercased()))
                case .centered:
                    out.append(Element(kind: .centered, text: String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)))
                case .character:
                    var cue = t.hasPrefix("@") ? String(t.dropFirst()) : t
                    let dual = cue.hasSuffix("^")
                    if dual { cue = String(cue.dropLast()).trimmingCharacters(in: .whitespaces) }
                    out.append(Element(kind: .character, text: cue, dual: dual))
                case .parenthetical:
                    out.append(Element(kind: .parenthetical, text: t)) // classify only gives these straight after a cue
                case .dialogue:
                    out.append(Element(kind: .dialogue, text: t))
                case .action:
                    // Consecutive action lines form one paragraph; each source line keeps its own line break.
                    var ls: [String] = []
                    while i < lines.count, kinds[i] == .action {
                        var a = String(lines[i])
                        if a.hasPrefix("!") { a.removeFirst() }
                        ls.append(a.trimmingCharacters(in: .whitespaces))
                        i += 1
                    }
                    out.append(Element(kind: .action, text: ls.joined(separator: "\n")))
                    continue
                }
                i += 1
            }
        }
        return out
    }

    static func blocks(from scripts: [String], sceneNumbers: Bool) -> [Block] {
        var blocks: [Block] = []
        let els = elements(scripts)
        var i = 0
        while i < els.count {
            let e = els[i]
            switch e.kind {
            case .pageBreak:
                blocks.append(Block(kind: .pageBreak, lines: [], spaceBefore: 0))
            case .heading:
                var ls = wrap(runs(e.text), width: actionWidth).map { Line(runs: $0.map { var r = $0; r.bold = true; return r }) }
                if sceneNumbers { ls[0].sceneNumber = e.sceneNumber }
                blocks.append(Block(kind: .heading, lines: ls, spaceBefore: 2))
            case .transition:
                blocks.append(Block(kind: .transition, lines: wrap(runs(e.text), width: actionWidth).map { Line(runs: $0, align: .right) }, spaceBefore: 1))
            case .centered:
                blocks.append(Block(kind: .centered, lines: wrap(runs(e.text), width: actionWidth).map { Line(runs: $0, align: .center) }, spaceBefore: 1))
            case .action, .parenthetical, .dialogue:
                let ls = e.text.split(separator: "\n", omittingEmptySubsequences: false)
                    .flatMap { wrap(runs(String($0)), width: actionWidth).map { Line(runs: $0) } }
                blocks.append(Block(kind: .action, lines: ls, spaceBefore: 1))
            case .character:
                var ls = [Line(runs: runs(e.text), indent: cueIndent)]
                var speech: [(paren: Bool, text: String)] = []
                while i + 1 < els.count, els[i + 1].kind == .dialogue || els[i + 1].kind == .parenthetical {
                    i += 1
                    let d = els[i]
                    speech.append((d.kind == .parenthetical, d.text))
                    ls += d.kind == .parenthetical
                        ? wrap(runs(d.text), width: parenWidth).map { Line(runs: $0, indent: parenIndent) }
                        : wrap(runs(d.text), width: dialogueWidth).map { Line(runs: $0, indent: dialogueIndent) }
                }
                if e.dual, let prev = blocks.last, prev.kind == .dialogue, let prevCue = prev.cue {
                    blocks[blocks.count - 1] = Block(kind: .dual, lines: dualLines(left: (prevCue, prev.speech), right: (e.text, speech)), spaceBefore: prev.spaceBefore)
                } else {
                    blocks.append(Block(kind: .dialogue, lines: ls, spaceBefore: 1, cue: e.text, speech: speech))
                }
            }
            i += 1
        }
        return blocks
    }

    // MARK: Dual dialogue

    // Two 28-character columns: left starts at the margin, right at character 31.
    static let dualWidth = 28, dualRight = 31, dualCue = 8, dualParen = 3, dualParenWidth = 23

    static func column(_ cue: String, _ speech: [(paren: Bool, text: String)], at x: Int) -> [(runs: [Run], indent: Int)] {
        var out = [(runs: runs(cue), indent: x + dualCue)]
        for s in speech {
            if s.paren { out += wrap(runs(s.text), width: dualParenWidth).map { ($0, x + dualParen) } }
            else { out += wrap(runs(s.text), width: dualWidth).map { ($0, x) } }
        }
        return out
    }

    static func dualLines(left: (String, [(paren: Bool, text: String)]), right: (String, [(paren: Bool, text: String)])) -> [Line] {
        let l = column(left.0, left.1, at: 0), r = column(right.0, right.1, at: dualRight)
        return (0..<Swift.max(l.count, r.count)).map { i in
            var line = Line(runs: i < l.count ? l[i].runs : [], indent: i < l.count ? l[i].indent : 0)
            if i < r.count { line.right = r[i].runs; line.rightIndent = r[i].indent }
            return line
        }
    }

    // MARK: Pagination

    public static func paginate(_ scripts: [String], options: Options = Options()) -> [Page] {
        let blocks = blocks(from: scripts, sceneNumbers: options.sceneNumbers)
        let max = options.linesPerPage
        var pages: [Page] = []
        var page: Page = []
        func newPage() { if !page.isEmpty { pages.append(page) }; page = [] }
        func room() -> Int { max - page.count }

        var queue = blocks[...]
        while var block = queue.popFirst() {
            if block.kind == .pageBreak { newPage(); continue }
            let space = page.isEmpty ? 0 : block.spaceBefore
            // A heading must not end a page: it needs the first two lines of what follows (or all of it).
            var need = block.lines.count
            if block.kind == .heading, let next = queue.first, next.kind != .pageBreak {
                need += next.spaceBefore + min(next.lines.count, 2)
            }
            if space + need <= room() {
                page += Array(repeating: nil, count: space) + block.lines.map { Optional($0) }
                continue
            }
            let avail = room() - space
            switch block.kind {
            case .action where block.lines.count >= 4 && avail >= 2:
                let k = min(avail, block.lines.count - 2)
                page += Array(repeating: nil, count: space) + block.lines.prefix(k).map { Optional($0) }
                newPage()
                block.lines = Array(block.lines.dropFirst(k)); block.spaceBefore = 0
                queue.insert(block, at: queue.startIndex)
            case .dialogue where avail >= 3 && block.lines.count >= 3:
                // Cue plus at least one line here, at least one line there, and room for (MORE).
                var k = min(avail - 1, block.lines.count - 1)
                while k > 1, block.lines[k - 1].indent == parenIndent { k -= 1 } // never break right after a parenthetical
                // Prefer to break after a sentence ends, as long as at least two lines of speech stay on this page.
                if let end = (3...Swift.max(3, k)).reversed().first(where: { j in
                    j <= k && block.lines[j - 1].indent == dialogueIndent
                        && [".", "?", "!", "…", "—", "-"].contains(where: block.lines[j - 1].text.trimmingCharacters(in: .whitespaces).hasSuffix)
                }) { k = end } else if block.lines.count <= max { fallthrough } // no sentence end here: move the speech whole
                if k < 2 { fallthrough }
                page += Array(repeating: nil, count: space) + block.lines.prefix(k).map { Optional($0) }
                page.append(Line(runs: [Run("(MORE)")], indent: cueIndent))
                newPage()
                let cue = block.cue ?? ""
                let contd = cue.uppercased().contains("CONT'D") ? cue : cue + " (CONT'D)"
                block.lines = [Line(runs: runs(contd), indent: cueIndent)] + block.lines.dropFirst(k)
                block.spaceBefore = 0
                queue.insert(block, at: queue.startIndex)
            default:
                if page.isEmpty, block.lines.count > max {
                    // Taller than a whole page: fill this page and carry the rest over, never drop lines.
                    page = block.lines.prefix(max).map { Optional($0) }
                    block.lines = Array(block.lines.dropFirst(max))
                    block.spaceBefore = 0
                } else {
                    newPage()
                }
                newPage()
                queue.insert(block, at: queue.startIndex)
            }
        }
        newPage()
        return pages
    }

    // MARK: Title page

    public struct TitlePage: Sendable {
        public var centre: [Line] = []
        public var bottomLeft: [Line] = []
        public var isEmpty: Bool { centre.isEmpty && bottomLeft.isEmpty }
    }

    /// Fountain title page keys (`Title:`, `Credit:`, `Author:`, `Source:`, `Draft date:`, `Contact:`),
    /// with indented lines continuing a value.
    public static func titlePage(_ text: String) -> TitlePage {
        var fields: [(String, [String])] = []
        for raw in Fountain.lines(MarkdownFile(text: text).body) {
            let line = String(raw)
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                fields.append((key, value.isEmpty ? [] : [value]))
            } else if !fields.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                fields[fields.count - 1].1.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        func values(_ keys: String...) -> [String] { fields.filter { keys.contains($0.0) }.flatMap(\.1) }
        var page = TitlePage()
        let title = values("title")
        if !title.isEmpty {
            page.centre += title.map { Line(runs: runs($0.uppercased()).map { var r = $0; r.bold = true; r.underline = true; return r }, align: .center) }
            page.centre.append(Line(runs: []))
        }
        for (i, group) in [values("credit"), values("author", "authors"), values("source")].enumerated() where !group.isEmpty {
            if i > 0 { page.centre.append(Line(runs: [])) }
            page.centre += group.map { Line(runs: runs($0), align: .center) }
        }
        page.bottomLeft = (values("draft date") + [""] + values("contact")).map { Line(runs: runs($0)) }
        while page.bottomLeft.first?.text.isEmpty == true { page.bottomLeft.removeFirst() }
        while page.bottomLeft.last?.text.isEmpty == true { page.bottomLeft.removeLast() }
        if page.centre.last?.text.isEmpty == true { page.centre.removeLast() }
        return page
    }
}

/// The title page file (front-matter.md) as editable fields; keys Spring doesn't show are kept.
public enum TitlePageFile {
    public static let keys = ["Title", "Credit", "Author", "Source", "Draft date", "Contact"]

    /// Key → value, multi-line values joined with "\n".
    public static func fields(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var last: String?
        for raw in Fountain.lines(MarkdownFile(text: text).body) {
            let line = String(raw)
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                out[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                last = key
            } else if let k = last, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let v = out[k] ?? ""
                out[k] = (v.isEmpty ? "" : v + "\n") + line.trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    /// Writes fields back in the usual order (others after), keeping any frontmatter.
    public static func text(_ fields: [String: String], updating original: String) -> String {
        var file = MarkdownFile(text: original)
        let order = keys.filter { fields[$0] != nil } + fields.keys.filter { !keys.contains($0) }.sorted()
        file.body = order.compactMap { k -> String? in
            let lines = (fields[k] ?? "").components(separatedBy: "\n")
            if lines.count > 1 { return "\(k):\n" + lines.map { "    " + $0 }.joined(separator: "\n") }
            return "\(k): \(lines[0])"
        }.joined(separator: "\n") + "\n"
        return file.text
    }
}
