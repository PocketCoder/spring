import AppKit
import Sparkle
import SpringCore
import SwiftUI

@main
struct SpringApp: App {
    // ponytail: no @State; Command Line Tools lack the SwiftUI macro plugin, and App is created once anyway.
    private let model = ProjectModel()
    /// Starts only when the build carries a public key, so local and `swift run` builds never prompt (as in cria).
    private let updater = SPUStandardUpdaterController(
        startingUpdater: !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty,
        updaterDelegate: nil, userDriverDelegate: nil)
    private var canUpdate: Bool { !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty }

    init() {
        // `Spring --export-pdf <project> <out.pdf>`: renders without opening a window (used to check layout).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-pdf"), args.count > i + 2 {
            for f in (try? FileManager.default.contentsOfDirectory(at: URL(filePath: "Resources/Fonts"), includingPropertiesForKeys: nil)) ?? [] {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
            let root = URL(filePath: args[i + 1], directoryHint: .isDirectory)
            let scenes = (try? ProjectIO.loadScenes(in: root)) ?? []
            let title = try? String(contentsOf: root.appending(path: "front-matter.md"), encoding: .utf8)
            let out = URL(filePath: args[i + 2]), scripts = scenes.map(\.file.body)
            let data: Data? = switch out.pathExtension {
            case "docx": DOCX.document(scripts: scripts, titlePage: title, pageSize: (595.28, 841.89))
            case "fdx": Data(FDX.document(scripts: scripts, titlePage: title).utf8)
            default: PDFExport.render(scripts: scripts, titlePage: title, paper: .a4, sceneNumbers: args.contains("--scene-numbers"),
                                      watermark: args.firstIndex(of: "--watermark").map { args[$0 + 1] } ?? "")
            }
            try? data?.write(to: out)
            exit(0)
        }
        // Needed when launched as a bare executable (`swift run`); harmless inside the .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Spring") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear {
                    Prefs.applyTheme()
                    model.restoreLastProject()
                    NSApp.activate()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
                    .disabled(!canUpdate)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { model.newProject() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Project…") { model.chooseProject() }.keyboardShortcut("o")
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Script…") { model.showFind = true }.keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.projectURL == nil)
            }
            CommandMenu("Scene") {
                Button("New Scene") { model.newScene() }.keyboardShortcut("n").disabled(model.projectURL == nil)
                Button("Split Scene at Cursor") { NSApp.sendAction(#selector(SceneTextView.splitHere(_:)), to: nil, from: nil) }
                    .keyboardShortcut("k")
                Button("Merge with Next Scene") { if let id = model.currentScene { model.mergeWithNext(id) } }
                Divider()
                Button("Move Scene Up") { if let id = model.currentScene { model.moveScene(id, by: -1) } }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                Button("Move Scene Down") { if let id = model.currentScene { model.moveScene(id, by: 1) } }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                Divider()
                Button("Take Snapshot") { if let id = model.currentScene { model.takeSnapshot(id) } }.keyboardShortcut("5")
                Button("Snapshots…") { model.snapshotSelection = nil; model.showSnapshots = true }
                    .keyboardShortcut("5", modifiers: [.command, .shift])
                Divider()
                Button("Send Scene to Graveyard") { if let id = model.currentScene { model.buryScene(id) } }
                Divider()
                Button("Script Report") { model.showReport = true }.keyboardShortcut("r", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .printItem) {
                Button("Print…") { model.printScript() }.keyboardShortcut("p").disabled(model.projectURL == nil)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Send to Graveyard") { NSApp.sendAction(#selector(SceneTextView.sendToGraveyard(_:)), to: nil, from: nil) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandGroup(before: .sidebar) {
                Button("Script") { model.viewMode = .script }.keyboardShortcut("1")
                Button("Corkboard") { model.viewMode = .cards }.keyboardShortcut("2")
                Button(model.continuous ? "Show One Scene at a Time" : "Show Continuous Script") { model.continuous.toggle() }
                    .keyboardShortcut("3")
                Button("Previous Scene") { step(-1) }.keyboardShortcut("[")
                Button("Next Scene") { step(1) }.keyboardShortcut("]")
                Button("Binder") { model.binder = model.binder == .detailOnly ? .all : .detailOnly }
                    .keyboardShortcut("b", modifiers: [.command, .control])
                Divider()
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveAll() }.keyboardShortcut("s")
            }
            CommandGroup(replacing: .importExport) {
                Button("Export PDF…") { model.exportPDF() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.projectURL == nil)
                Button("Export Final Draft…") { model.export(as: "fdx") }.disabled(model.projectURL == nil)
                Button("Export Word Document…") { model.export(as: "docx") }.disabled(model.projectURL == nil)
                Button("Export Fountain…") { model.exportFountain() }.disabled(model.projectURL == nil)
            }
        }
        Settings { SettingsView() }
    }

    private func step(_ by: Int) {
        guard let id = model.currentScene, let i = model.scenes.firstIndex(where: { $0.id == id }) else { return }
        let j = i + by
        if model.scenes.indices.contains(j) { model.focus(model.scenes[j].id, atEnd: false); model.scrollTarget = model.scenes[j].id }
    }
}
