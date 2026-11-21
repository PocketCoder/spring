import Foundation

public enum LineKind: Equatable, Sendable {
    case blank, heading, action, character, parenthetical, dialogue, transition, centered, section, synopsis, note, pageBreak
}

/// Line-by-line Fountain classifier (https://fountain.io/syntax). Covers what the editor styles;
/// boneyard, dual dialogue layout and emphasis are not handled yet.
public enum Fountain {
    static let headingPrefixes = ["INT/EXT", "I/E", "INT", "EXT", "EST"]

    public static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    public static func isHeading(_ line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("."), !t.hasPrefix(".."), t.count > 1 { return true }
        let u = t.uppercased()
        return headingPrefixes.contains { p in
            u.hasPrefix(p) && (u.dropFirst(p.count).first.map { $0 == "." || $0 == " " } ?? false)
        }
    }

    /// Heading as shown in the scene list: forced "." and scene numbers removed.
    public static func headingText(_ line: Substring) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(".") { t.removeFirst() }
        if let r = t.range(of: #"\s*#[^#]*#\s*$"#, options: .regularExpression) { t.removeSubrange(r) }
        return t.uppercased()
    }

    static func isCue(_ t: String) -> Bool {
        var s = t
        if s.hasSuffix("^") { s.removeLast() }
        if let p = s.firstIndex(of: "(") { s = String(s[..<p]) }
        return s.unicodeScalars.contains { CharacterSet.letters.contains($0) } && s == s.uppercased()
    }

    public static func classify(_ text: String) -> [LineKind] {
        let lines = lines(text)
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        var kinds: [LineKind] = []
        kinds.reserveCapacity(lines.count)
        for i in lines.indices {
            let t = trimmed[i]
            let prev = kinds.last ?? .blank
            let prevBlank = i == 0 || trimmed[i - 1].isEmpty
            let nextBlank = i + 1 >= lines.count || trimmed[i + 1].isEmpty
            let kind: LineKind
            if t.isEmpty { kind = .blank }
            else if [.character, .dialogue, .parenthetical].contains(prev) { kind = t.hasPrefix("(") ? .parenthetical : .dialogue }
            else if t.hasPrefix("!") { kind = .action }
            else if t.hasPrefix("@") { kind = .character }
            else if t.count >= 3, t.allSatisfy({ $0 == "=" }) { kind = .pageBreak }
            else if t.hasPrefix("#") { kind = .section }
            else if t.hasPrefix("=") { kind = .synopsis }
            else if t.hasPrefix("[["), t.hasSuffix("]]") { kind = .note }
            else if t.hasPrefix(">"), t.hasSuffix("<") { kind = .centered }
            else if t.hasPrefix(">") { kind = .transition }
            else if prevBlank, isHeading(lines[i]) { kind = .heading }
            else if prevBlank, nextBlank, t.hasSuffix("TO:"), t == t.uppercased() { kind = .transition }
            else if prevBlank, !nextBlank, isCue(t) { kind = .character }
            else { kind = .action }
            kinds.append(kind)
        }
        return kinds
    }

    public static func headings(in text: String) -> [String] {
        let lines = lines(text)
        return zip(lines, classify(text)).compactMap { $1 == .heading ? headingText($0) : nil }
    }

    /// Dual dialogue: line ranges of the speech before a `^` cue (left, blank lines between included) and the `^`
    /// speech itself (right).
    public static func dualPairs(_ text: String, kinds: [LineKind]? = nil) -> [(left: Range<Int>, right: Range<Int>)] {
        let lines = lines(text)
        let kinds = kinds ?? classify(text)
        var pairs: [(left: Range<Int>, right: Range<Int>)] = []
        var lastSpeech: Range<Int>?
        var i = 0
        while i < lines.count {
            guard kinds[i] == .character else {
                if kinds[i] != .blank { lastSpeech = nil }
                i += 1
                continue
            }
            var end = i + 1
            while end < lines.count, kinds[end] == .dialogue || kinds[end] == .parenthetical { end += 1 }
            let isDual = lines[i].trimmingCharacters(in: .whitespaces).hasSuffix("^")
            if isDual, let prev = lastSpeech {
                pairs.append((prev.lowerBound..<i, i..<end))
                lastSpeech = nil
            } else {
                lastSpeech = i..<end
            }
            i = end
        }
        return pairs
    }
}
