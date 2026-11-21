import AppKit
import Observation
import SpringCore

@MainActor @Observable
final class ProjectModel {
    var projectURL: URL?
    var scenes: [SceneFile] = []
    var conflicts: Set<UUID> = []
    var errorMessage: String?
    var marker: FountainMarker = .tag
    var sceneListHovered = false

    @ObservationIgnored private var pending: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var scopedURL: URL?
    private static let bookmarkKey = "lastProjectBookmark"

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveAll() }
        }
    }

    // MARK: Opening

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Project"
        panel.message = "Choose a project folder that contains a Scenes folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        open(url)
    }

    func restoreLastProject() {
        // Dev convenience: `swift run Spring /path/to/project` (unsandboxed builds only).
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            return open(URL(filePath: path, directoryHint: .isDirectory))
        }
        guard projectURL == nil, let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        open(url)
    }

    func open(_ url: URL) {
        saveAll()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        do {
            scenes = try ProjectIO.loadScenes(in: url)
            projectURL = url
            conflicts = []
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Editing and saving

    func body(of id: UUID) -> String { scenes.first { $0.id == id }?.file.body ?? "" }

    func update(_ id: UUID, body: String) {
        guard let i = scenes.firstIndex(where: { $0.id == id }), scenes[i].file.body != body else { return }
        scenes[i].file.body = body
        scheduleSave(id)
    }

    func updateSynopsis(_ id: UUID, _ text: String) {
        guard let i = scenes.firstIndex(where: { $0.id == id }), scenes[i].explicitSynopsis != text else { return }
        scenes[i].setSynopsis(text)
        scheduleSave(id)
    }

    // MARK: Corkboard

    enum ViewMode { case script, cards }
    var viewMode: ViewMode = .script
    var selected: UUID?
    var dropTarget: UUID?
    /// Set to scroll the script view to a scene (from a card double-click).
    var scrollTarget: UUID?

    /// Moves `id` to just before `target` (or to the end), then writes the new numbers to every file that changed.
    func move(_ id: UUID, before target: UUID?) {
        guard id != target, let from = scenes.firstIndex(where: { $0.id == id }) else { return }
        let scene = scenes.remove(at: from)
        let to = target.flatMap { t in scenes.firstIndex { $0.id == t } } ?? scenes.endIndex
        scenes.insert(scene, at: to)
        for (i, s) in scenes.enumerated() where s.number != i + 1 { save(s.id, rename: false) }
    }

    func openInScript(_ id: UUID) {
        viewMode = .script
        scrollTarget = id
    }

    private func scheduleSave(_ id: UUID) {
        pending[id]?.cancel()
        pending[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save(id, rename: false)
        }
    }

    /// Typing saves without renaming; the rename (and link fix-up) waits until you leave the scene.
    func save(_ id: UUID, rename: Bool) {
        pending[id]?.cancel()
        pending[id] = nil
        guard let i = scenes.firstIndex(where: { $0.id == id }), !conflicts.contains(id) else { return }
        var scene = scenes[i]
        do {
            switch try ProjectIO.save(&scene, number: i + 1, marker: marker, rename: rename) {
            case .saved(let oldURL):
                scenes[i] = scene
                if let oldURL, let root = projectURL { ProjectIO.updateLinks(under: root, from: oldURL, to: scene.url) }
            case .conflict: conflicts.insert(id)
            }
        } catch {
            errorMessage = "Couldn't save \(scene.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func saveAll() {
        for id in scenes.map(\.id) where pending[id] != nil || needsRename(id) { save(id, rename: true) }
    }

    func finishEditing(_ id: UUID) {
        if pending[id] != nil || needsRename(id) { save(id, rename: true) }
    }

    private func needsRename(_ id: UUID) -> Bool {
        guard let s = scenes.first(where: { $0.id == id }) else { return false }
        return ProjectIO.targetURL(for: s).lastPathComponent != s.url.lastPathComponent
    }

    /// Conflict: overwrite the file on disk with Spring's version.
    func keepMine(_ id: UUID) {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[i].knownModDate = nil
        conflicts.remove(id)
        save(id, rename: true)
    }

    /// Conflict: drop Spring's edits and load the file from disk.
    func reload(_ id: UUID) {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        pending[id]?.cancel()
        pending[id] = nil
        do {
            let fresh = try ProjectIO.read(scenes[i].url)
            scenes[i].file = fresh.file
            scenes[i].knownModDate = fresh.knownModDate
            conflicts.remove(id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
