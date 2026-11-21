import Foundation

public enum FountainMarker: String, Sendable { case tag, cssclass }

public struct SceneFile: Identifiable, Sendable {
    public let id = UUID()
    public var url: URL
    public var file: MarkdownFile
    /// Modification date when Spring last read or wrote the file; a newer date on disk means someone else edited it.
    public var knownModDate: Date?

    public var number: Int? { file.value("scene").flatMap { Int($0) } }
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
        SceneFile(url: url, file: MarkdownFile(text: try String(contentsOf: url, encoding: .utf8)), knownModDate: modDate(url))
    }

    /// Scenes ordered by their `scene` property, then file name.
    /// ponytail: `.fountain`/`.txt` carry no frontmatter, so they sort by name only.
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

    public enum SaveResult: Equatable { case saved, conflict }

    /// Writes the scene, sets its number and Fountain marker, and renames it after its first heading.
    /// Returns `.conflict` without writing if the file changed on disk since Spring last saw it.
    public static func save(_ scene: inout SceneFile, number: Int, marker: FountainMarker) throws -> SaveResult {
        if let disk = modDate(scene.url), let known = scene.knownModDate, disk > known { return .conflict }
        let name = scene.url.lastPathComponent.lowercased()
        if name.hasSuffix(".md") {
            scene.file.set("scene", String(number))
            if !name.hasSuffix(".fountain.md") {
                marker == .tag ? scene.file.ensureListItem("tags", "fountain") : scene.file.ensureListItem("cssclasses", "fountain")
            }
        }
        try scene.file.text.write(to: scene.url, atomically: true, encoding: .utf8)
        let target = targetURL(for: scene)
        if target.lastPathComponent != scene.url.lastPathComponent {
            try FileManager.default.moveItem(at: scene.url, to: target)
            scene.url = target
        }
        scene.knownModDate = modDate(scene.url)
        return .saved
    }
}
