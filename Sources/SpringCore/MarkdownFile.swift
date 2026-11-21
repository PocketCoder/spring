import Foundation

/// A text file split into YAML frontmatter lines and body. Frontmatter is edited line by line
/// so keys Spring doesn't know about are written back untouched.
public struct MarkdownFile: Equatable, Sendable {
    public var frontmatter: [String]?
    public var body: String

    public init(text: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
            frontmatter = lines[1..<end].map(String.init)
            body = lines[(end + 1)...].joined(separator: "\n")
        } else {
            frontmatter = nil
            body = lines.joined(separator: "\n")
        }
    }

    public var text: String {
        guard let fm = frontmatter else { return body }
        return (["---"] + fm + ["---"]).joined(separator: "\n") + "\n" + body
    }

    public func value(_ key: String) -> String? {
        guard let line = frontmatter?.first(where: { $0.hasPrefix(key + ":") }) else { return nil }
        let v = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\"'")))
        return v.isEmpty ? nil : v
    }

    public mutating func set(_ key: String, _ value: String) {
        var fm = frontmatter ?? []
        if let i = fm.firstIndex(where: { $0.hasPrefix(key + ":") }) { fm[i] = "\(key): \(value)" } else { fm.append("\(key): \(value)") }
        frontmatter = fm
    }

    /// Adds `item` to a list property (`tags`, `cssclasses`), in inline or block form, if missing.
    public mutating func ensureListItem(_ key: String, _ item: String) {
        var fm = frontmatter ?? []
        let strip = CharacterSet.whitespaces.union(.init(charactersIn: "\"'"))
        guard let i = fm.firstIndex(where: { $0.hasPrefix(key + ":") }) else {
            frontmatter = fm + ["\(key):", "  - \(item)"]
            return
        }
        let inline = fm[i].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if inline.isEmpty {
            var j = i + 1
            var items: [String] = []
            while j < fm.count, fm[j].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                items.append(fm[j].trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: strip))
                j += 1
            }
            if !items.contains(item) { fm.insert("  - \(item)", at: j) }
        } else {
            var items = inline.trimmingCharacters(in: .init(charactersIn: "[]"))
                .split(separator: ",").map { $0.trimmingCharacters(in: strip) }.filter { !$0.isEmpty }
            if !items.contains(item) {
                items.append(item)
                fm[i] = "\(key): [\(items.joined(separator: ", "))]"
            }
        }
        frontmatter = fm
    }
}
