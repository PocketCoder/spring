import Foundation

public enum FountainMarker: String, Sendable { case tag, cssclass }

/// How scene files are named: after the first heading, number + heading ("003 INT. BAR - NIGHT"), or left alone.
public enum SceneNaming: String, Sendable { case heading, numbered, keep }

public struct SceneFile: Identifiable, Sendable {
    public let id = UUID()
    public var url: URL
    public var file: MarkdownFile
    /// Modification date when Spring last read or wrote the file; a newer date on disk means someone else edited it.
    public var knownModDate: Date?
    /// `.fountain`/`.txt` have no frontmatter: their number lives in a hidden first-line note, `[[scene: 3]]`.
    public var noteNumber: Int?
    /// What's on disk as of the last read or write; lets a rename made elsewhere be recognised by content.
    public var savedText: String?

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
        let raw = try String(contentsOf: url, encoding: .utf8)
        var scene = SceneFile(url: url, file: MarkdownFile(text: raw), knownModDate: modDate(url))
        scene.savedText = raw
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

    /// Rewrites `[text](old%20name.md)`, `[text](Scenes/old%20name.md#part)` and `[text](<old name.md>)`.
    public static func rewriteMarkdownLinks(in text: String, from oldFile: String, to newFile: String) -> String {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))) ?? s }
        var out = text
        for (old, new) in [(enc(oldFile), enc(newFile)), (oldFile, newFile)] {
            let pattern = #"\]\((<?)((?:[^)>\n]*/)?)"# + NSRegularExpression.escapedPattern(for: old) + #"((?:#[^)>\n]*)?>?\))"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let tpl = NSRegularExpression.escapedTemplate(for: new)
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "]($1$2" + tpl + "$3")
        }
        return out
    }

    /// Renames a file in place (extension kept) and returns its new URL.
    public static func rename(_ url: URL, to name: String) throws -> URL {
        let ext = ext(of: url) ?? (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let target = url.deletingLastPathComponent().appending(path: clean + ext)
        guard target.lastPathComponent != url.lastPathComponent else { return url }
        guard !FileManager.default.fileExists(atPath: target.path) || target.path.lowercased() == url.path.lowercased() else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// After a rename, fixes links in every `.md` and `.canvas` file under `root`.
    /// ponytail: only the folder Spring can reach (the project, or the vault once it is chosen in Settings);
    public static func updateLinks(under root: URL, from oldURL: URL, to newURL: URL) {
        let oldLink = linkName(of: oldURL), newLink = linkName(of: newURL)
        let oldFile = oldURL.lastPathComponent, newFile = newURL.lastPathComponent
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in files {
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "canvas", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let updated = ext == "md"
                ? rewriteMarkdownLinks(in: rewriteLinks(in: text, from: oldLink, to: newLink), from: oldFile, to: newFile)
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
    public static func targetURL(for scene: SceneFile, number: Int? = nil, naming: SceneNaming = .heading) -> URL {
        if naming == .keep { return scene.url }
        let ext = ext(of: scene.url) ?? ".fountain.md"
        let clean = scene.heading.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        guard !clean.isEmpty else { return scene.url }
        let base = naming == .numbered ? String(format: "%03d ", number ?? scene.number ?? 0) + clean : clean
        let dir = scene.url.deletingLastPathComponent()
        var n = 1
        while true {
            let url = dir.appending(path: base + (n == 1 ? "" : " \(n)") + ext)
            let same = url.path.lowercased() == scene.url.path.lowercased()
            if same || !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    public enum SaveResult: Equatable { case saved(renamedFrom: URL?), conflict }

    /// Writes the scene and sets its number and Fountain marker. With `rename`, also renames it after its
    /// first heading (callers then fix links with `updateLinks`).
    /// Returns `.conflict` without writing if the file changed on disk since Spring last saw it.
    public static func save(_ scene: inout SceneFile, number: Int, marker: FountainMarker, rename: Bool = true,
                                   naming: SceneNaming = .heading) throws -> SaveResult {
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
        let target = targetURL(for: scene, number: number, naming: naming)
        if rename, target.lastPathComponent != scene.url.lastPathComponent {
            try FileManager.default.moveItem(at: scene.url, to: target)
            renamedFrom = scene.url
            scene.url = target
        }
        scene.knownModDate = modDate(scene.url)
        scene.savedText = scene.diskText
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
    public static func newScene(in project: URL, ext: String, template: String? = nil) throws -> SceneFile {
        let dir = project.appending(path: "Scenes")
        var url = dir.appending(path: "Untitled scene\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appending(path: "Untitled scene \(n)\(ext)"); n += 1 }
        var file = MarkdownFile(text: template ?? "INT. \n")
        if file.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { file.body = "INT. \n" }
        var scene = SceneFile(url: url, file: file)
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
    public static func graveyardFile(for scene: SceneFile, in project: URL) -> URL {
        let name = scene.heading.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return project.appending(path: "Graveyard/\(name).md")
    }

    public static func bury(_ text: String, from scene: SceneFile, in project: URL, date: Date = .now) throws -> URL {
        _ = try graveyard(project)
        let url = graveyardFile(for: scene, in: project)
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
        file.savedText = file.diskText
        return .saved(renamedFrom: nil)
    }

    /// A plain file opened as raw text (frontmatter included), for the note editor.
    public static func readRaw(_ url: URL) throws -> SceneFile {
        var f = SceneFile(url: url, file: MarkdownFile(text: ""), knownModDate: modDate(url))
        f.file.body = try String(contentsOf: url, encoding: .utf8)
        return f
    }

    /// `Untitled.md` (numbered if taken) in `folder`.
    public static func newNote(in folder: URL, name: String = "Untitled", text: String = "") throws -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = folder.appending(path: "\(clean).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appending(path: "\(clean) \(n).md"); n += 1 }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: Keeping up with changes made outside Spring (Obsidian, Finder, sync)

extension ProjectIO {
    public struct SyncResult {
        public var scenes: [SceneFile]
        public var conflicts: Set<UUID>
        /// False when nothing on disk differed from what Spring holds.
        public var changed: Bool
    }

    static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().path.lowercased() }

    /// Brings the in-memory scenes up to date with `Scenes/`:
    /// files changed outside are reloaded, unless Spring has unsaved edits (`dirty`), which makes them conflicts;
    /// new files are added; files deleted or renamed outside are dropped (the new name is picked up as a new file).
    public static func sync(_ scenes: [SceneFile], dirty: Set<UUID>, conflicts: Set<UUID>, in project: URL) -> SyncResult {
        let dir = project.appending(path: "Scenes")
        let onDisk = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { ext(of: $0) != nil }
        var conflicts = conflicts
        var changed = false
        var result: [SceneFile] = []
        let held = Set(scenes.map { key($0.url) })
        var unclaimed = onDisk.filter { !held.contains(key($0)) }
        for var s in scenes {
            guard FileManager.default.fileExists(atPath: s.url.path) else {
                // Renamed elsewhere (Obsidian, Finder): a new file with exactly what Spring last saw is this scene.
                if let saved = s.savedText,
                   let i = unclaimed.firstIndex(where: { (try? String(contentsOf: $0, encoding: .utf8)) == saved }) {
                    s.url = unclaimed.remove(at: i)
                    s.knownModDate = modDate(s.url)
                    result.append(s)
                    changed = true
                } else if dirty.contains(s.id) {
                    conflicts.insert(s.id); result.append(s)
                } else {
                    changed = true
                }
                continue
            }
            if let disk = modDate(s.url), let known = s.knownModDate, disk > known {
                if dirty.contains(s.id) || conflicts.contains(s.id) {
                    conflicts.insert(s.id)
                } else if let fresh = try? read(s.url) {
                    s.file = fresh.file
                    s.noteNumber = fresh.noteNumber
                    s.knownModDate = fresh.knownModDate
                    changed = true
                }
            }
            result.append(s)
        }
        let known = Set(result.map { key($0.url) })
        for url in onDisk where !known.contains(key(url)) {
            if let s = try? read(url) { result.append(s); changed = true }
        }
        if changed {
            result = result.enumerated().sorted {
                ($0.element.number ?? .max, $0.offset) < ($1.element.number ?? .max, $1.offset)
            }.map(\.element)
        }
        return SyncResult(scenes: result, conflicts: conflicts, changed: changed)
    }
}

// MARK: Colour labels (corkboard)
extension SceneFile {
    public static let labels = ["red", "orange", "yellow", "green", "blue", "purple"]
    /// A `color` property, so the label also shows in Obsidian's Properties. Markdown scenes only.
    public var colorLabel: String? { isMarkdown ? file.value("color").map { $0.lowercased() } : nil }
    public var canLabel: Bool { isMarkdown }
    public mutating func setColorLabel(_ name: String?) {
        guard isMarkdown else { return }
        if let name { file.set("color", name) } else { file.frontmatter?.removeAll { $0.hasPrefix("color:") } }
    }
}

// MARK: Splitting scenes and snapshots
extension ProjectIO {
    /// Splits a scene body at a UTF-16 offset; the new scene starts at the next non-blank line.
    public static func split(_ body: String, at offset: Int) -> (String, String) {
        let ns = body as NSString
        let o = min(max(0, offset), ns.length)
        let first = ns.substring(to: o).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "\n"
        let second = ns.substring(from: o).replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
        return (first, second.isEmpty ? "INT. \n" : second)
    }

    /// Snapshots live in a hidden folder, so Obsidian and the binder don't list them: .spring/snapshots/<scene name>/.
    public static func snapshotFolder(for scene: URL, in project: URL) -> URL {
        project.appending(path: ".spring/snapshots/\(stem(of: scene))", directoryHint: .isDirectory)
    }

    @discardableResult
    public static func snapshot(_ scene: SceneFile, in project: URL, title: String = "", date: Date = .now) throws -> URL {
        let dir = snapshotFolder(for: scene.url, in: project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let clean = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = dir.appending(path: f.string(from: date) + (clean.isEmpty ? "" : " " + clean) + ".md")
        try scene.file.body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Newest first.
    public static func snapshots(for scene: URL, in project: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: snapshotFolder(for: scene, in: project), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Keeps snapshots with their scene when it's renamed.
    public static func moveSnapshots(from old: URL, to new: URL, in project: URL) {
        let a = snapshotFolder(for: old, in: project), b = snapshotFolder(for: new, in: project)
        guard a != b, FileManager.default.fileExists(atPath: a.path), !FileManager.default.fileExists(atPath: b.path) else { return }
        try? FileManager.default.moveItem(at: a, to: b)
    }
}

// MARK: Script report
public struct ScriptReport: Sendable {
    public struct Speaker: Sendable { public let name: String; public let speeches: Int; public let words: Int; public let scenes: Int }
    public struct Place: Sendable { public let name: String; public let scenes: Int }
    public var scenes = 0, words = 0, interior = 0, exterior = 0, day = 0, night = 0
    public var speakers: [Speaker] = []
    public var places: [Place] = []

    public init(bodies: [String]) {
        var speeches: [String: (Int, Int, Set<Int>)] = [:]
        var placeCount: [String: Int] = [:]
        for (i, body) in bodies.enumerated() {
            words += body.split(whereSeparator: { $0.isWhitespace }).count
            for h in Fountain.headings(in: body) {
                scenes += 1
                let u = h.uppercased()
                if u.hasPrefix("INT") || u.hasPrefix("I/E") { interior += 1 }
                if u.hasPrefix("EXT") || u.hasPrefix("I/E") || u.hasPrefix("INT./EXT") || u.hasPrefix("INT/EXT") { exterior += 1 }
                if u.hasSuffix("NIGHT") { night += 1 } else if u.hasSuffix("DAY") || u.hasSuffix("MORNING") || u.hasSuffix("AFTERNOON") { day += 1 }
                if let loc = Autocomplete.location(ofHeading: h) { placeCount[loc, default: 0] += 1 }
            }
            let lines = Fountain.lines(body), kinds = Fountain.classify(body)
            var current: String?
            for (line, kind) in zip(lines, kinds) {
                switch kind {
                case .character:
                    let name = Autocomplete.cueName(line)
                    current = name
                    var e = speeches[name] ?? (0, 0, [])
                    e.0 += 1; e.2.insert(i)
                    speeches[name] = e
                case .dialogue:
                    if let c = current { speeches[c]?.1 += line.split(whereSeparator: { $0.isWhitespace }).count }
                case .parenthetical: break
                default: current = nil
                }
            }
        }
        speakers = speeches.map { Speaker(name: $0.key, speeches: $0.value.0, words: $0.value.1, scenes: $0.value.2.count) }
            .sorted { ($0.speeches, $1.name) > ($1.speeches, $0.name) }
        places = placeCount.map { Place(name: $0.key, scenes: $0.value) }.sorted { ($0.scenes, $1.name) > ($1.scenes, $0.name) }
    }
}
