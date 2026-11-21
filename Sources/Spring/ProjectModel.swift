import AppKit
import Observation
import PDFKit
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
    @ObservationIgnored private var watcher: FolderWatcher?
    private static let bookmarkKey = "lastProjectBookmark"

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveAll(); self?.saveNote(); self?.saveBoard() }
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
        rememberRecent(url)
        do {
            scenes = try ProjectIO.loadScenes(in: url)
            note = nil
            viewMode = .script
            tree = ProjectIO.tree(at: url, folderOrder: Prefs.projectFolders)
            loadBoard()
            sessionStartWords = wordCount
            updatePages()
            watcher = FolderWatcher(url) { [weak self] in self?.syncWithDisk() }
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
        for (i, s) in scenes.enumerated() where s.number != i + 1 { save(s.id, rename: Prefs.naming == .numbered) }
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
            switch try ProjectIO.save(&scene, number: i + 1, marker: marker, rename: rename, naming: Prefs.naming) {
            case .saved(let oldURL):
                scenes[i] = scene
                updatePages()
                if let oldURL, let root = projectURL {
                    ProjectIO.updateLinks(under: vaultContaining(root) ?? root, from: oldURL, to: scene.url)
                    ProjectIO.moveSnapshots(from: oldURL, to: scene.url, in: root)
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
        let n = (scenes.firstIndex { $0.id == id } ?? 0) + 1
        return ProjectIO.targetURL(for: s, number: n, naming: Prefs.naming).lastPathComponent != s.url.lastPathComponent
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

    /// A new scene straight after the one you're in (or at the end), or with the given text (when splitting).
    func newScene(text: String? = nil) {
        guard let root = projectURL else { return }
        do {
            let scene = try ProjectIO.newScene(in: root, ext: Prefs.saveExt, template: text ?? templateText(Prefs.templateScene, title: "Untitled scene"))
            let at = focusedScene.flatMap { id in scenes.firstIndex { $0.id == id } }.map { $0 + 1 } ?? scenes.endIndex
            scenes.insert(scene, at: at)
            for (n, s) in scenes.enumerated() where s.number != n + 1 || s.id == scene.id { save(s.id, rename: Prefs.naming == .numbered) }
            openInScript(scene.id)
            focus(scene.id, atEnd: false)
            refreshTree()
        } catch {
            errorMessage = "Couldn't create a scene: \(error.localizedDescription)"
        }
    }

    /// Selected text, already cut from the scene, goes to Graveyard/<heading>.md.
    /// Returns the undo: the Graveyard file as it was before.
    func bury(_ text: String, from id: UUID) -> () -> Void {
        guard let root = projectURL, let scene = scenes.first(where: { $0.id == id }) else { return {} }
        let file = ProjectIO.graveyardFile(for: scene, in: root)
        let before = try? String(contentsOf: file, encoding: .utf8)
        do {
            try ProjectIO.bury(text, from: scene, in: root)
            refreshTree()
            showToast("Moved to Graveyard/\(file.lastPathComponent)") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
        } catch {
            errorMessage = "Couldn't write to the Graveyard: \(error.localizedDescription)"
        }
        return { [weak self] in
            if let before { try? before.write(to: file, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: file) }
            self?.refreshTree()
        }
    }

    /// Moves the whole scene file into Graveyard/ and renumbers the rest.
    func buryScene(_ id: UUID) {
        guard let root = projectURL, let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        save(id, rename: false)
        do {
            let original = scenes[i].url
            let buried = try ProjectIO.bury(file: original, in: root)
            showToast("Moved \(original.lastPathComponent) to the Graveyard") { [weak self] in
                try? FileManager.default.moveItem(at: buried, to: original)
                self?.syncWithDisk()
            }
            scenes.remove(at: i)
            pending[id] = nil
            if selected == id { selected = nil }
            for (n, s) in scenes.enumerated() where s.number != n + 1 { save(s.id, rename: Prefs.naming == .numbered) }
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

    func newNote(in folder: URL, text: String? = nil) {
        do {
            let key = switch folder.lastPathComponent {
            case "Characters": Prefs.templateCharacter
            case "Locations": Prefs.templateLocation
            default: Prefs.templateNote
            }
            let prompt = folder.lastPathComponent == "Characters" ? "New character (e.g. BILLY (M24) - Shopkeeper)" : "New note in \(folder.lastPathComponent)"
            guard let name = askForText(prompt, initial: "") else { return }
            let url = try ProjectIO.newNote(in: folder, name: name, text: text ?? templateText(key, title: name) ?? "")
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

    // MARK: Obsidian vault (optional)

    /// Resolved once per launch; access stays open for the app's lifetime.
    static let vault: URL? = {
        guard let data = UserDefaults.standard.data(forKey: Prefs.vaultBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }()

    static func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Vault"
        panel.message = "Choose your Obsidian vault (the folder that contains .obsidian)."
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: Prefs.vaultBookmark)
        UserDefaults.standard.set(url.path, forKey: Prefs.vaultPath)
        _ = url.startAccessingSecurityScopedResource()
    }

    static func clearVault() {
        UserDefaults.standard.removeObject(forKey: Prefs.vaultBookmark)
        UserDefaults.standard.removeObject(forKey: Prefs.vaultPath)
    }

    /// The vault, if this project is inside it.
    func vaultContaining(_ url: URL) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: Prefs.vaultPath), !path.isEmpty,
              url.standardizedFileURL.path.hasPrefix(path.hasSuffix("/") ? path : path + "/") else { return nil }
        _ = Self.vault
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Path as Obsidian writes it in a canvas: relative to the vault, or "<project>/…" when no vault is set.
    func vaultRelativePath(_ url: URL) -> String {
        guard let root = projectURL else { return url.lastPathComponent }
        let file = url.standardizedFileURL.path
        if let vault = vaultContaining(root) { return String(file.dropFirst(vault.standardizedFileURL.path.count + 1)) }
        return root.lastPathComponent + "/" + String(file.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    // MARK: Beats board (Beats/Board.canvas)

    var showBeats = false
    var board: CanvasBoard?
    var selectedCard: String?
    @ObservationIgnored private var boardModDate: Date?
    @ObservationIgnored private var boardSave: Task<Void, Never>?

    var boardURL: URL? { projectURL?.appending(path: "Beats/Board.canvas") }

    func loadBoard() {
        guard let url = boardURL else { return }
        board = (try? Data(contentsOf: url)).flatMap { try? CanvasBoard(data: $0) }
        boardModDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func editBoard(_ change: (inout CanvasBoard) -> Void) {
        var b = board ?? CanvasBoard()
        change(&b)
        board = b
        boardSave?.cancel()
        boardSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveBoard()
        }
    }

    func saveBoard() {
        boardSave?.cancel()
        boardSave = nil
        guard let url = boardURL, let board else { return }
        let disk = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let disk, let known = boardModDate, disk > known {
            loadBoard()
            errorMessage = "Board.canvas was changed outside Spring, so Spring reloaded it. Your last change to the board wasn't saved."
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try board.data.write(to: url, options: .atomic)
            boardModDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            refreshTree()
        } catch {
            errorMessage = "Couldn't save the beat board: \(error.localizedDescription)"
        }
    }

    /// The scene a file card points at, matched on its vault path or its end.
    func scene(forCardFile file: String) -> SceneFile? {
        scenes.first { vaultRelativePath($0.url) == file || $0.url.path.hasSuffix("/" + file) }
    }

    // MARK: Autocomplete

    private func stems(in folder: String) -> [String] {
        guard let root = projectURL,
              let items = try? FileManager.default.contentsOfDirectory(at: root.appending(path: folder), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return [] }
        return items.filter { $0.pathExtension.lowercased() == "md" }.map(ProjectIO.stem(of:))
    }

    func suggestions(for line: String, afterBlank: Bool) -> [String] {
        let bodies = scenes.map(\.file.body)
        return Autocomplete.suggestions(
            for: line, afterBlank: afterBlank,
            characters: Autocomplete.characters(fileStems: stems(in: "Characters"), sceneBodies: bodies),
            locations: Autocomplete.locations(fileStems: stems(in: "Locations"), sceneBodies: bodies))
    }

    // MARK: Changes made outside Spring

    /// Runs on every file-system change in the project (including Spring's own saves, which are no-ops here).
    func syncWithDisk() {
        guard let root = projectURL else { return }
        let dirty = Set(pending.keys)
        let r = ProjectIO.sync(scenes, dirty: dirty, conflicts: conflicts, in: root)
        if r.changed { scenes = r.scenes }
        if r.conflicts != conflicts { conflicts = r.conflicts }
        if let id = selected, !scenes.contains(where: { $0.id == id }) { selected = nil }
        refreshTree()
        syncNote()
        syncBoard()
    }

    private func syncNote() {
        guard let n = note else { return }
        guard FileManager.default.fileExists(atPath: n.url.path) else {
            if noteSave == nil { note = nil; viewMode = .script } else { noteConflict = true }
            return
        }
        let disk = (try? FileManager.default.attributesOfItem(atPath: n.url.path))?[.modificationDate] as? Date
        guard let disk, let known = n.knownModDate, disk > known else { return }
        if noteSave == nil, !noteConflict { note = try? ProjectIO.readRaw(n.url) } else { noteConflict = true }
    }

    private func syncBoard() {
        guard let url = boardURL, boardSave == nil else { return }
        let disk = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if disk != boardModDate { loadBoard() }
    }

    // MARK: Templates

    /// A folder chosen by hand, else the one the vault's Templates / Templater settings name.
    static var templatesFolder: URL? {
        if let data = UserDefaults.standard.data(forKey: Prefs.templatesBookmark) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }
        return vault.flatMap(Templates.folder(inVault:))
    }

    static func chooseTemplatesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder of Markdown templates."
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: Prefs.templatesBookmark)
        UserDefaults.standard.set(url.path, forKey: Prefs.templatesPath)
    }

    static func clearTemplatesFolder() {
        UserDefaults.standard.removeObject(forKey: Prefs.templatesBookmark)
        UserDefaults.standard.removeObject(forKey: Prefs.templatesPath)
    }

    /// The chosen template for `key`, filled in, or nil when none is set or it can't be read.
    func templateText(_ key: String, title: String) -> String? {
        guard let name = UserDefaults.standard.string(forKey: key), !name.isEmpty,
              let folder = Self.templatesFolder,
              let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8) else { return nil }
        return Templates.render(text, title: title)
    }

    // MARK: Recent projects and the status line

    private static let recentsKey = "recentProjects"
    /// The scene the cursor is in, for the status line.
    var focusedScene: UUID?

    var recents: [URL] {
        (UserDefaults.standard.array(forKey: Self.recentsKey) as? [Data] ?? []).compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    private func rememberRecent(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var list = (UserDefaults.standard.array(forKey: Self.recentsKey) as? [Data] ?? []).filter { d in
            var stale = false
            let u = try? URL(resolvingBookmarkData: d, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            return u?.standardizedFileURL != url.standardizedFileURL
        }
        list.insert(data, at: 0)
        UserDefaults.standard.set(Array(list.prefix(6)), forKey: Self.recentsKey)
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    func openRecent(_ url: URL) { open(url) }

    var wordCount: Int {
        scenes.reduce(0) { $0 + $1.file.body.split(whereSeparator: { $0.isWhitespace }).count }
    }

    // MARK: Focus across scenes, single-scene view, toast

    struct FocusRequest: Equatable { let id: UUID; let atEnd: Bool; let token: Int; var range: NSRange? = nil }
    var focusRequest: FocusRequest?
    @ObservationIgnored private var focusToken = 0

    /// Script view shows every scene (true) or one at a time.
    var continuous = UserDefaults.standard.object(forKey: "continuousScript") as? Bool ?? true {
        didSet { UserDefaults.standard.set(continuous, forKey: "continuousScript") }
    }

    /// The scene shown in single-scene view.
    var currentScene: UUID? { focusedScene.flatMap { id in scenes.contains { $0.id == id } ? id : nil } ?? scenes.first?.id }

    func focus(_ id: UUID, atEnd: Bool, select range: NSRange? = nil) {
        focusToken += 1
        focusedScene = id
        focusRequest = FocusRequest(id: id, atEnd: atEnd, token: focusToken, range: range)
        if range != nil { viewMode = .script; scrollTarget = id }
        updatePages()
    }

    /// Arrow keys off the top or bottom of a scene move into the neighbouring one.
    func leave(_ id: UUID, up: Bool) -> Bool {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return false }
        let j = up ? i - 1 : i + 1
        guard scenes.indices.contains(j) else { return false }
        focus(scenes[j].id, atEnd: up)
        return true
    }

    struct Toast { let message: String; let undo: (() -> Void)?; let id = UUID() }
    var toast: Toast?

    func showToast(_ message: String, undo: (() -> Void)? = nil) {
        let t = Toast(message: message, undo: undo)
        toast = t
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    func setLabel(_ id: UUID, _ name: String?) {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[i].setColorLabel(name)
        save(id, rename: false)
    }

    /// Renames a file from the binder and fixes links to it across the project (or vault).
    func renameFile(_ url: URL, to name: String) {
        guard let root = projectURL else { return }
        if let i = scenes.firstIndex(where: { $0.url == url }) { save(scenes[i].id, rename: false) }
        if note?.url == url { saveNote() }
        do {
            let new = try ProjectIO.rename(url, to: name)
            if let i = scenes.firstIndex(where: { $0.url == url }) { scenes[i].url = new }
            if note?.url == url { note?.url = new }
            ProjectIO.updateLinks(under: vaultContaining(root) ?? root, from: url, to: new)
            refreshTree()
        } catch {
            errorMessage = "Couldn't rename \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Find and replace

    enum Panel { case find, scene }
    /// The right-hand panel: Find, or the scene inspector.
    var panel: Panel?
    var showFind: Bool {
        get { panel == .find }
        set { panel = newValue ? .find : (panel == .find ? nil : panel) }
    }

    /// Characters and locations a scene mentions, with their notes when they exist.
    func people(in id: UUID) -> [(name: String, note: URL?)] {
        guard let root = projectURL, let s = scenes.first(where: { $0.id == id }) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "Characters"), includingPropertiesForKeys: nil)) ?? []
        let names = Autocomplete.characters(fileStems: [], sceneBodies: [s.file.body])
        return names.map { n in (n, files.first { Autocomplete.characterName(fromFileStem: ProjectIO.stem(of: $0)) == n }) }
    }

    func places(in id: UUID) -> [(name: String, note: URL?)] {
        guard let root = projectURL, let s = scenes.first(where: { $0.id == id }) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "Locations"), includingPropertiesForKeys: nil)) ?? []
        let locs = Autocomplete.locations(fileStems: [], sceneBodies: [s.file.body])
        return locs.map { l in (l, files.first { l.hasPrefix(ProjectIO.stem(of: $0).uppercased()) }) }
    }
    var findQuery = ""
    var replaceText = ""
    var findCaseSensitive = false
    var findWholeWords = false

    var findResults: [Search.Match] {
        Search.find(findQuery, in: scenes.map(\.file.body), caseSensitive: findCaseSensitive, wholeWords: findWholeWords)
    }

    func replaceAll() {
        let count = findResults.count
        guard count > 0 else { return }
        let before = scenes.map { ($0.id, $0.file.body) }
        for s in scenes {
            update(s.id, body: Search.replaceAll(findQuery, with: replaceText, in: s.file.body, caseSensitive: findCaseSensitive, wholeWords: findWholeWords))
        }
        showToast("Replaced \(count) \(count == 1 ? "match" : "matches")") { [weak self] in
            for (id, body) in before { self?.update(id, body: body) }
        }
    }

    // MARK: Rename a character everywhere

    /// Renames the character file and every cue for them; links to the file are updated.
    func renameCharacter(file url: URL) {
        let stem = ProjectIO.stem(of: url)
        let old = Autocomplete.characterName(fromFileStem: stem)
        guard let new = askForText("Rename \(old) in every scene", initial: old)?.uppercased(), new != old else { return }
        var changed = 0
        for s in scenes {
            let body = Search.renameCharacter(old, to: new, in: s.file.body)
            if body != s.file.body { changed += 1; update(s.id, body: body) }
        }
        let rest = stem.dropFirst(stem.uppercased().hasPrefix(old) ? old.count : 0)
        renameFile(url, to: new + rest)
        showToast("Renamed \(old) to \(new) in \(changed) \(changed == 1 ? "scene" : "scenes")")
    }

    // MARK: Pages

    var pageCount = 0
    var focusedPage: Int?

    /// Page count and the page the cursor's scene starts on, as the PDF would print (A4 or Letter from export settings).
    func updatePages() {
        let paper = PDFExport.Paper(rawValue: UserDefaults.standard.string(forKey: "pdfPaper") ?? "") ?? .a4
        let options = Screenplay.Options(linesPerPage: paper.linesPerPage)
        let bodies = scenes.map(\.file.body)
        pageCount = Screenplay.paginate(bodies, options: options).count
        if let id = focusedScene, let i = scenes.firstIndex(where: { $0.id == id }) {
            focusedPage = i == 0 ? 1 : Screenplay.paginate(Array(bodies.prefix(i + 1)), options: options).count
        } else {
            focusedPage = nil
        }
    }

    func printScript() {
        guard let root = projectURL else { return }
        let d = UserDefaults.standard
        let paper = PDFExport.Paper(rawValue: d.string(forKey: "pdfPaper") ?? "") ?? .a4
        let title = (d.object(forKey: "pdfTitlePage") == nil || d.bool(forKey: "pdfTitlePage"))
            ? try? String(contentsOf: root.appending(path: "front-matter.md"), encoding: .utf8) : nil
        let data = PDFExport.render(scripts: scenes.map(\.file.body), titlePage: title, paper: paper,
                                    sceneNumbers: d.bool(forKey: "pdfSceneNumbers"), watermark: d.string(forKey: "pdfWatermark") ?? "")
        guard let doc = PDFDocument(data: data) else { return }
        let info = NSPrintInfo.shared
        info.paperSize = paper.size
        doc.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false)?.runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Scene commands

    func splitScene(_ id: UUID, at offset: Int) {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        let (first, second) = ProjectIO.split(scenes[i].file.body, at: offset)
        scenes[i].file.body = first
        save(id, rename: true)
        focusedScene = id
        newScene(text: second)
    }

    /// Joins a scene with the next one; the next one's file goes to the Graveyard, so nothing is lost.
    func mergeWithNext(_ id: UUID) {
        guard let root = projectURL, let i = scenes.firstIndex(where: { $0.id == id }), i + 1 < scenes.count else { return }
        let next = scenes[i + 1]
        scenes[i].file.body = scenes[i].file.body.trimmingCharacters(in: .newlines) + "\n\n" + next.file.body
        save(id, rename: false)
        do { _ = try ProjectIO.bury(file: next.url, in: root) } catch { errorMessage = error.localizedDescription; return }
        scenes.remove(at: i + 1)
        for (n, s) in scenes.enumerated() where s.number != n + 1 { save(s.id, rename: Prefs.naming == .numbered) }
        refreshTree()
        showToast("Merged. \(next.url.lastPathComponent) is in the Graveyard")
    }

    func moveScene(_ id: UUID, by delta: Int) {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard scenes.indices.contains(j) else { return }
        move(id, before: delta < 0 ? scenes[j].id : (j + 1 < scenes.count ? scenes[j + 1].id : nil))
    }

    // MARK: Snapshots

    var showSnapshots = false
    var snapshotSelection: URL?

    func takeSnapshot(_ id: UUID, title: String = "") {
        guard let root = projectURL, let s = scenes.first(where: { $0.id == id }) else { return }
        do {
            try ProjectIO.snapshot(s, in: root, title: title)
            showToast("Snapshot taken of \(s.heading)")
        } catch { errorMessage = "Couldn't take a snapshot: \(error.localizedDescription)" }
    }

    func snapshots(_ id: UUID) -> [URL] {
        guard let root = projectURL, let s = scenes.first(where: { $0.id == id }) else { return [] }
        return ProjectIO.snapshots(for: s.url, in: root)
    }

    /// Restores a snapshot, after snapshotting the current text so the restore can itself be undone.
    func restoreSnapshot(_ url: URL, into id: UUID) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        takeSnapshot(id, title: "before restore")
        update(id, body: text)
        showToast("Restored snapshot from \(url.deletingPathExtension().lastPathComponent)")
    }

    // MARK: Session

    var showReport = false
    @ObservationIgnored var sessionStartWords: Int?

    // MARK: Focus mode, title page, Obsidian, copying

    /// Just the page: no toolbar, scene list, status line, binder or panel.
    var focusMode = false {
        didSet { if focusMode { binder = .detailOnly; panel = nil } }
    }

    var showTitlePage = false
    var titleFields: [String: String] = [:]

    func editTitlePage() {
        guard let root = projectURL else { return }
        titleFields = TitlePageFile.fields((try? String(contentsOf: root.appending(path: "front-matter.md"), encoding: .utf8)) ?? "")
        showTitlePage = true
    }

    func saveTitlePage() {
        guard let root = projectURL else { return }
        let url = root.appending(path: "front-matter.md")
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        do { try TitlePageFile.text(titleFields.filter { !$0.value.isEmpty }, updating: original).write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = "Couldn't save the title page: \(error.localizedDescription)" }
        showTitlePage = false
    }

    /// Opens a file in Obsidian (obsidian://open?path=…). Needs the file to be inside an Obsidian vault.
    func openInObsidian(_ url: URL) {
        var c = URLComponents(string: "obsidian://open")!
        c.queryItems = [URLQueryItem(name: "path", value: url.path)]
        if let link = c.url, !NSWorkspace.shared.open(link) { errorMessage = "Couldn't open Obsidian. Is it installed?" }
    }

    /// The whole script as one Fountain text on the clipboard (scenes are separate files, so it can't be selected in one go).
    func copyWholeScript() {
        let text = scenes.map { $0.file.body.trimmingCharacters(in: .newlines) }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Copied the whole script (\(scenes.count) scenes)")
    }
}
