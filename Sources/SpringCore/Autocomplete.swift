import Foundation

/// Suggestions for character cues and scene headings, from the project's Characters/ and Locations/ files
/// and from what the scenes already use.
public enum Autocomplete {
    public static let times = ["DAY", "NIGHT", "MORNING", "AFTERNOON", "EVENING", "CONTINUOUS", "LATER", "MOMENTS LATER"]
    public static let extensions = ["V.O.", "O.S.", "CONT'D"]

    /// "BILLY (M24) - Shopkeeper" → "BILLY"; "Mrs Hale - Landlady" → "MRS HALE".
    public static func characterName(fromFileStem stem: String) -> String {
        var s = stem
        if let r = s.range(of: " (") { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of: " - ") { s = String(s[..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// Cue without extensions or the dual-dialogue caret: "SARAH (V.O.) ^" → "SARAH".
    static func cueName(_ line: Substring) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("@") { s.removeFirst() }
        if s.hasSuffix("^") { s.removeLast() }
        if let p = s.firstIndex(of: "(") { s = String(s[..<p]) }
        return s.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// Heading's location: "INT. HOUSE - KITCHEN - DAY" → "HOUSE - KITCHEN".
    static func location(ofHeading heading: String) -> String? {
        guard let prefix = headingPrefix(heading) else { return nil }
        var rest = String(heading.dropFirst(prefix.count))
        if let r = rest.range(of: " - ", options: .backwards), times.contains(String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)) {
            rest = String(rest[..<r.lowerBound])
        }
        let loc = rest.trimmingCharacters(in: .whitespaces)
        return loc.isEmpty ? nil : loc
    }

    /// "INT. ", "EXT. ", "INT./EXT. ", "I/E " and the like at the start of a line, as typed.
    static func headingPrefix(_ line: String) -> String? {
        let u = line.uppercased()
        for p in ["INT./EXT. ", "INT/EXT ", "EXT./INT. ", "I/E. ", "I/E ", "INT. ", "EXT. ", "EST. ", "INT ", "EXT ", "EST "] where u.hasPrefix(p) {
            return String(line.prefix(p.count))
        }
        return nil
    }

    public static func characters(fileStems: [String], sceneBodies: [String]) -> [String] {
        var names = fileStems.map(characterName(fromFileStem:))
        for body in sceneBodies {
            names += zip(Fountain.lines(body), Fountain.classify(body)).compactMap { $1 == .character ? cueName($0) : nil }
        }
        return unique(names)
    }

    public static func locations(fileStems: [String], sceneBodies: [String]) -> [String] {
        var locs = fileStems.map { $0.uppercased() }
        for body in sceneBodies { locs += Fountain.headings(in: body).compactMap(location(ofHeading:)) }
        return unique(locs)
    }

    static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { !$0.isEmpty && seen.insert($0).inserted }.sorted()
    }

    /// Whole-line completions for `line` (the text from line start to the cursor).
    /// `afterBlank` is true when the previous line is empty (where a cue can start).
    public static func suggestions(for line: String, afterBlank: Bool, characters: [String], locations: [String]) -> [String] {
        if let prefix = headingPrefix(line) {
            let rest = String(line.dropFirst(prefix.count))
            if let r = rest.range(of: " - ", options: .backwards) {
                let typed = rest[r.upperBound...].uppercased()
                let head = prefix + rest[..<r.upperBound]
                let whole = rest.uppercased()
                return locations.filter { $0.hasPrefix(whole) && $0 != whole }.map { prefix + $0 }
                    + times.filter { $0.hasPrefix(typed) && $0 != typed }.map { head + $0 }
            }
            let typed = rest.uppercased()
            guard !typed.isEmpty else { return locations.map { prefix + $0 } }
            return locations.filter { $0.hasPrefix(typed) && $0 != typed }.map { prefix + $0 }
        }
        guard afterBlank else { return [] }
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("("), t.dropLast().trimmingCharacters(in: .whitespaces) == t.dropLast().trimmingCharacters(in: .whitespaces).uppercased() {
            return extensions.map { t + $0 + ")" }
        }
        guard t == t.uppercased(), t.unicodeScalars.contains(where: CharacterSet.letters.contains),
              Fountain.headingPrefixes.allSatisfy({ !$0.hasPrefix(t) }) else { return [] }
        return characters.filter { $0.hasPrefix(t) && $0 != t }
    }
}
