import Foundation

public enum FountainMarker: String, Sendable { case tag, cssclass }

public struct SceneFile: Identifiable, Sendable {
    public let id = UUID()
    public var url: URL
    public var file: MarkdownFile
    /// Modification date when Spring last read or wrote the file; a newer date on disk means someone else edited it.
    public var knownModDate: Date?
    /// `.fountain`/`.txt` have no frontmatter: their number lives in a hidden first-line note, `[[scene: 3]]`.
    public var noteNumber: Int?

    public init(url: URL, file: MarkdownFile, knownModDate: Date? = nil) {
        self.url = url
        self.file = file
        self.knownModDate = knownModDate
    }

    public var number: Int? { file.value("scene").flatMap { Int($0) } ?? noteNumber }
    var isMarkdown: Bool { url.lastPathComponent.lowercased().hasSuffix(".md") }

    /// What goes on disk: frontmatter for markdown, the scene note otherwise.
    public var diskText: String {
        guard !isMarkdown, let n = noteNumber else { return file.text }
        return "[[scene: \(n)]]\n" + file.text
    }
    public var heading: String { Fountain.headings(in: file.body).first ?? ProjectIO.stem(of: url) }
}

public enum ProjectIO {
    /// Longest first, so `.fountain.md` wins over `.md`.
    public static let sceneExtensions = [".fountain.md", ".fountain", ".md", ".txt"]

    public static func ext(of url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        return sceneExtensions.first { name.hasSuffix($0) }
    }

    public static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        return String(name.dropLast(ext(of: url)?.count ?? 0))
    }

    static func modDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public static func read(_ url: URL) throws -> SceneFile {
        var scene = SceneFile(url: url, file: MarkdownFile(text: try String(contentsOf: url, encoding: .utf8)), knownModDate: modDate(url))
        if !scene.isMarkdown, let match = scene.file.body.firstMatch(of: #/^\[\[scene:\s*(\d+)\]\]\n?/#) {
            scene.noteNumber = Int(match.1)
            scene.file.body.removeSubrange(match.range)
        }
        return scene
    }

    /// The name Obsidian uses in `[[links]]`: the file name, minus `.md`.
    public static func linkName(of url: URL) -> String {
        let name = url.lastPathComponent
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// Rewrites `[[old]]`, `[[old|alias]]`, `[[old#heading]]` and `[[folder/old]]` links.
    public static func rewriteLinks(in text: String, from old: String, to new: String) -> String {
        guard let re = try? Regex("\\[\\[((?:[^\\]|#\\n]*/)?)" + NSRegularExpression.escapedPattern(for: old) + "(?=[\\]|#])") else { return text }
        return text.replacing(re) { "[[" + String($0.output[1].substring ?? "") + new }
    }

    /// After a rename, fixes links in every `.md` and `.canvas` file under `root`.
    /// ponytail: only the folder Spring can reach (the project, or the vault once it is chosen in Settings);
    /// markdown-style `[text](path.md)` links are not rewritten.
    public static func updateLinks(under root: URL, from oldURL: URL, to newURL: URL) {
        let oldLink = linkName(of: oldURL), newLink = linkName(of: newURL)
        let oldFile = oldURL.lastPathComponent, newFile = newURL.lastPathComponent
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in files {
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "canvas", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let updated = ext == "md"
                ? rewriteLinks(in: text, from: oldLink, to: newLink)
                : text.replacingOccurrences(of: "/\(oldFile)\"", with: "/\(newFile)\"").replacingOccurrences(of: "\"\(oldFile)\"", with: "\"\(newFile)\"")
            if updated != text { try? updated.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    /// Scenes ordered by their `scene` property, then file name.
    public static func loadScenes(in project: URL) throws -> [SceneFile] {
        let dir = project.appending(path: "Scenes")
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { ext(of: $0) != nil }
            .map(read)
            .sorted { ($0.number ?? .max, $0.url.lastPathComponent) < ($1.number ?? .max, $1.url.lastPathComponent) }
    }

    /// File name for a heading: path separators removed, numbered if another file already has it.
    public static func targetURL(for scene: SceneFile) -> URL {
        let ext = ext(of: scene.url) ?? ".fountain.md"
        let clean = scene.heading.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        guard !clean.isEmpty else { return scene.url }
        let dir = scene.url.deletingLastPathComponent()
        var n = 1
        while true {
            let url = dir.appending(path: clean + (n == 1 ? "" : " \(n)") + ext)
            let same = url.path.lowercased() == scene.url.path.lowercased()
            if same || !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    public enum SaveResult: Equatable { case saved(renamedFrom: URL?), conflict }

    /// Writes the scene and sets its number and Fountain marker. With `rename`, also renames it after its
    /// first heading (callers then fix links with `updateLinks`).
    /// Returns `.conflict` without writing if the file changed on disk since Spring last saw it.
    public static func save(_ scene: inout SceneFile, number: Int, marker: FountainMarker, rename: Bool = true) throws -> SaveResult {
        if let disk = modDate(scene.url), let known = scene.knownModDate, disk > known { return .conflict }
        let name = scene.url.lastPathComponent.lowercased()
        if !scene.isMarkdown { scene.noteNumber = number }
        if name.hasSuffix(".md") {
            scene.file.set("scene", String(number))
            if !name.hasSuffix(".fountain.md") {
                marker == .tag ? scene.file.ensureListItem("tags", "fountain") : scene.file.ensureListItem("cssclasses", "fountain")
            }
        }
        try scene.diskText.write(to: scene.url, atomically: true, encoding: .utf8)
        var renamedFrom: URL?
        let target = targetURL(for: scene)
        if rename, target.lastPathComponent != scene.url.lastPathComponent {
            try FileManager.default.moveItem(at: scene.url, to: target)
            renamedFrom = scene.url
            scene.url = target
        }
        scene.knownModDate = modDate(scene.url)
        return .saved(renamedFrom: renamedFrom)
    }
}

// MARK: Synopsis
// Markdown scenes keep it in a `synopsis` property (shows in Obsidian's Properties);
// .fountain/.txt use Fountain's own `= synopsis` line under the heading.
extension SceneFile {
    /// The synopsis the writer set, if any.
    public var explicitSynopsis: String {
        if isMarkdown { return file.value("synopsis") ?? "" }
        return synopsisLine.map { Fountain.lines(file.body)[$0].trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// What a card shows: the synopsis, else the first line of action.
    public var cardText: String {
        let s = explicitSynopsis
        if !s.isEmpty { return s }
        let lines = Fountain.lines(file.body)
        return zip(lines, Fountain.classify(file.body)).first { $1 == .action }.map { String($0.0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    public mutating func setSynopsis(_ text: String) {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if isMarkdown {
            let escaped = clean.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            file.set("synopsis", "\"\(escaped)\"")
            return
        }
        var lines = Fountain.lines(file.body).map(String.init)
        if let i = synopsisLine {
            if clean.isEmpty { lines.remove(at: i) } else { lines[i] = "= " + clean }
        } else if !clean.isEmpty {
            let heading = Fountain.classify(file.body).firstIndex(of: .heading)
            lines.insert("= " + clean, at: heading.map { $0 + 1 } ?? 0)
        }
        file.body = lines.joined(separator: "\n")
    }

    private var synopsisLine: Int? { Fountain.classify(file.body).firstIndex(of: .synopsis) }
}
