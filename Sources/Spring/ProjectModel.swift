import AppKit
import Observation
import SwiftUI
import SpringCore

@MainActor @Observable
final class ProjectModel {
    var projectURL: URL?
    var scenes: [SceneFile] = []
    var conflicts: Set<UUID> = []
    var errorMessage: String?
    var marker: FountainMarker { Prefs.fountainMarker }
    var sceneListHovered = false

    @ObservationIgnored private var pending: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var scopedURL: URL?
    private static let bookmarkKey = "lastProjectBookmark"

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveAll(); self?.saveNote() }
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
            note = nil
            viewMode = .script
            tree = ProjectIO.tree(at: url, folderOrder: Prefs.projectFolders)
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

    enum ViewMode { case script, cards, note }
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
                if let oldURL, let root = projectURL {
                    ProjectIO.updateLinks(under: root, from: oldURL, to: scene.url)
                    refreshTree()
                }
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

    // MARK: New project, new scene, Graveyard

    func newProject() {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Project name:"
        panel.nameFieldStringValue = "my-project"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectIO.createProject(at: url, folders: Prefs.projectFolders)
            if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            }
            open(url)
        } catch {
            errorMessage = "Couldn't create the project: \(error.localizedDescription)"
        }
    }

    func newScene() {
        guard let root = projectURL else { return }
        do {
            let scene = try ProjectIO.newScene(in: root, ext: Prefs.saveExt)
            scenes.append(scene)
            save(scene.id, rename: false)
            openInScript(scene.id)
            refreshTree()
        } catch {
            errorMessage = "Couldn't create a scene: \(error.localizedDescription)"
        }
    }

    /// Selected text, already cut from the scene, goes to Graveyard/<heading>.md.
    func bury(_ text: String, from id: UUID) {
        guard let root = projectURL, let scene = scenes.first(where: { $0.id == id }) else { return }
        do { try ProjectIO.bury(text, from: scene, in: root); refreshTree() } catch {
            errorMessage = "Couldn't write to the Graveyard: \(error.localizedDescription)"
        }
    }

    /// Moves the whole scene file into Graveyard/ and renumbers the rest.
    func buryScene(_ id: UUID) {
        guard let root = projectURL, let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        save(id, rename: false)
        do {
            _ = try ProjectIO.bury(file: scenes[i].url, in: root)
            scenes.remove(at: i)
            pending[id] = nil
            if selected == id { selected = nil }
            for (n, s) in scenes.enumerated() where s.number != n + 1 { save(s.id, rename: false) }
            refreshTree()
        } catch {
            errorMessage = "Couldn't move the scene to the Graveyard: \(error.localizedDescription)"
        }
    }

    // MARK: Binder and notes

    var binder: NavigationSplitViewVisibility = .detailOnly
    var tree: [FileNode] = []
    /// A non-scene file open in the note editor (raw text, frontmatter included).
    var note: SceneFile?
    var noteConflict = false
    @ObservationIgnored private var noteSave: Task<Void, Never>?

    func refreshTree() {
        if let root = projectURL { tree = ProjectIO.tree(at: root, folderOrder: Prefs.projectFolders) }
    }

    func openFile(_ url: URL) {
        if let scene = scenes.first(where: { $0.url == url }) { return openInScript(scene.id) }
        guard url.pathExtension.lowercased() != "canvas" else { NSWorkspace.shared.open(url); return }
        saveNote()
        do {
            note = try ProjectIO.readRaw(url)
            noteConflict = false
            viewMode = .note
        } catch {
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func updateNote(_ text: String) {
        guard note != nil, note?.file.body != text else { return }
        note?.file.body = text
        noteSave?.cancel()
        noteSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNote()
        }
    }

    func saveNote(force: Bool = false) {
        noteSave?.cancel()
        noteSave = nil
        guard var n = note, !noteConflict || force else { return }
        if force { n.knownModDate = nil }
        do {
            if try ProjectIO.write(&n) == .conflict { noteConflict = true } else { note = n; noteConflict = false }
        } catch {
            errorMessage = "Couldn't save \(n.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func reloadNote() {
        guard let url = note?.url else { return }
        noteConflict = false
        note = try? ProjectIO.readRaw(url)
    }

    func newNote(in folder: URL) {
        do {
            let url = try ProjectIO.newNote(in: folder)
            refreshTree()
            openFile(url)
        } catch {
            errorMessage = "Couldn't create a note: \(error.localizedDescription)"
        }
    }

    func buryFile(_ url: URL) {
        if let scene = scenes.first(where: { $0.url == url }) { return buryScene(scene.id) }
        guard let root = projectURL else { return }
        if note?.url == url { note = nil; viewMode = .script }
        do { _ = try ProjectIO.bury(file: url, in: root) } catch {
            errorMessage = "Couldn't move \(url.lastPathComponent) to the Graveyard: \(error.localizedDescription)"
        }
        refreshTree()
    }
}
