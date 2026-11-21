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

// MARK: Creating projects and scenes, and the Graveyard
extension ProjectIO {
    public static let defaultFolders = ["Scenes", "Characters", "Locations", "Beats", "Research", "Notes", "Graveyard"]

    /// Creates the folder layout plus `Logline.md` and `front-matter.md` (the Fountain title page).
    /// Never overwrites: existing files and folders are left alone.
    public static func createProject(at root: URL, folders: [String] = defaultFolders) throws {
        let fm = FileManager.default
        for f in Set(folders + ["Scenes"]) { try fm.createDirectory(at: root.appending(path: f), withIntermediateDirectories: true) }
        let title = root.lastPathComponent
        let starters = [
            "Logline.md": "# Logline\n\n",
            "front-matter.md": "Title: \(title)\nCredit: Written by\nAuthor: \nDraft date: \n",
        ]
        for (name, text) in starters where !fm.fileExists(atPath: root.appending(path: name).path) {
            try text.write(to: root.appending(path: name), atomically: true, encoding: .utf8)
        }
    }

    /// A new, empty scene file in `Scenes/`, named "Untitled scene" until it gets a heading.
    public static func newScene(in project: URL, ext: String) throws -> SceneFile {
        let dir = project.appending(path: "Scenes")
        var url = dir.appending(path: "Untitled scene\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appending(path: "Untitled scene \(n)\(ext)"); n += 1 }
        var scene = SceneFile(url: url, file: MarkdownFile(text: "INT. \n"))
        try scene.diskText.write(to: scene.url, atomically: true, encoding: .utf8)
        scene.knownModDate = modDate(scene.url)
        return scene
    }

    static func graveyard(_ project: URL) throws -> URL {
        let dir = project.appending(path: "Graveyard")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Appends cut text to `Graveyard/<heading>.md` with the date and a link back to the scene. Returns that file.
    @discardableResult
    public static func bury(_ text: String, from scene: SceneFile, in project: URL, date: Date = .now) throws -> URL {
        let name = scene.heading.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = try graveyard(project).appending(path: name + ".md")
        let stamp = date.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + " " + date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let entry = "## \(stamp) from [[\(linkName(of: scene.url))]]\n\n\(text.trimmingCharacters(in: .newlines))\n\n"
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (existing + entry).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Moves a whole scene file into `Graveyard/`, numbering the name if one is already there. Returns the new URL.
    public static func bury(file: URL, in project: URL) throws -> URL {
        let dir = try graveyard(project)
        let stem = stem(of: file), ext = ext(of: file) ?? ""
        var target = dir.appending(path: file.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appending(path: "\(stem) \(n)\(ext)")
            n += 1
        }
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}

// MARK: Binder tree and plain files

public struct FileNode: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let isFolder: Bool
    /// nil for files, so SwiftUI's OutlineGroup shows no disclosure arrow.
    public var children: [FileNode]?
    public var name: String { isFolder ? url.lastPathComponent : ProjectIO.stem(of: url) }
}

extension ProjectIO {
    static let binderExtensions = ["md", "fountain", "txt", "canvas"]

    /// Files and folders under `root`: top-level files first, then folders in `folderOrder`, then the rest A–Z.
    public static func tree(at root: URL, folderOrder: [String] = defaultFolders) -> [FileNode] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { return [] }
        let nodes: [FileNode] = items.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { return FileNode(url: url, isFolder: true, children: tree(at: url, folderOrder: [])) }
            return binderExtensions.contains(url.pathExtension.lowercased()) ? FileNode(url: url, isFolder: false) : nil
        }
        func rank(_ n: FileNode) -> Int {
            if !n.isFolder { return -1 }
            return folderOrder.firstIndex(of: n.url.lastPathComponent) ?? folderOrder.count
        }
        return nodes.sorted { (rank($0), $0.name.localizedLowercase) < (rank($1), $1.name.localizedLowercase) }
    }

    /// Writes a file as is (no scene number, marker or rename), refusing if it changed on disk.
    public static func write(_ file: inout SceneFile) throws -> SaveResult {
        if let disk = modDate(file.url), let known = file.knownModDate, disk > known { return .conflict }
        try file.diskText.write(to: file.url, atomically: true, encoding: .utf8)
        file.knownModDate = modDate(file.url)
        return .saved(renamedFrom: nil)
    }

    /// A plain file opened as raw text (frontmatter included), for the note editor.
    public static func readRaw(_ url: URL) throws -> SceneFile {
        var f = SceneFile(url: url, file: MarkdownFile(text: ""), knownModDate: modDate(url))
        f.file.body = try String(contentsOf: url, encoding: .utf8)
        return f
    }

    /// `Untitled.md` (numbered if taken) in `folder`.
    public static func newNote(in folder: URL) throws -> URL {
        var url = folder.appending(path: "Untitled.md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appending(path: "Untitled \(n).md"); n += 1 }
        try "".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
