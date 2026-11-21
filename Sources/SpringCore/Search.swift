import Foundation

/// Find and replace across every scene, and renaming a character everywhere they speak.
public enum Search {
    public struct Match: Identifiable, Equatable, Sendable {
        public var id: String { "\(scene)-\(range.location)" }
        public let scene: Int          // index into the scenes searched
        public let range: NSRange      // in the scene body
        public let line: String        // the whole line, for the results list
    }

    public static func find(_ query: String, in bodies: [String], caseSensitive: Bool = false, wholeWords: Bool = false) -> [Match] {
        guard !query.isEmpty, let re = regex(query, caseSensitive: caseSensitive, wholeWords: wholeWords) else { return [] }
        return bodies.enumerated().flatMap { i, body -> [Match] in
            let ns = body as NSString
            return re.matches(in: body, range: NSRange(location: 0, length: ns.length)).map { m in
                Match(scene: i, range: m.range, line: ns.substring(with: ns.lineRange(for: m.range)).trimmingCharacters(in: .newlines))
            }
        }
    }

    public static func replaceAll(_ query: String, with replacement: String, in body: String, caseSensitive: Bool = false, wholeWords: Bool = false) -> String {
        guard !query.isEmpty, let re = regex(query, caseSensitive: caseSensitive, wholeWords: wholeWords) else { return body }
        return re.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    static func regex(_ query: String, caseSensitive: Bool, wholeWords: Bool) -> NSRegularExpression? {
        let p = NSRegularExpression.escapedPattern(for: query)
        return try? NSRegularExpression(pattern: wholeWords ? "\\b\(p)\\b" : p, options: caseSensitive ? [] : [.caseInsensitive])
    }

    /// Renames a character's cues (keeping extensions like "(V.O.)" and "^"). Dialogue and action are left alone,
    /// since a name in prose may need a different case or form.
    public static func renameCharacter(_ old: String, to new: String, in body: String) -> String {
        let lines = Fountain.lines(body)
        let kinds = Fountain.classify(body)
        let oldU = old.uppercased(), newU = new.uppercased()
        return zip(lines, kinds).map { line, kind -> String in
            guard kind == .character else { return String(line) }
            let t = line.trimmingCharacters(in: .whitespaces)
            let forced = t.hasPrefix("@")
            let name = forced ? String(t.dropFirst()) : t
            let cut = name.firstIndex { $0 == "(" || $0 == "^" } ?? name.endIndex
            guard name[..<cut].trimmingCharacters(in: .whitespaces).uppercased() == oldU else { return String(line) }
            let rest = name[cut...]
            return (forced ? "@" : "") + newU + (rest.isEmpty ? "" : " " + rest.trimmingCharacters(in: .whitespaces))
        }.joined(separator: "\n")
    }
}
