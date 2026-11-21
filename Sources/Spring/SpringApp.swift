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
            case "docx": DOCXExport.document(scripts: scripts, titlePage: title, paper: .a4)
            case "fdx": Data(FDX.document(scripts: scripts, titlePage: title).utf8)
            default: PDFExport.render(scripts: scripts, titlePage: title, paper: .a4, sceneNumbers: args.contains("--scene-numbers"))
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
                Button("New Scene") { model.newScene() }.keyboardShortcut("n").disabled(model.projectURL == nil)
                Button("New Project…") { model.newProject() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Project…") { model.chooseProject() }.keyboardShortcut("o")
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Send to Graveyard") { NSApp.sendAction(#selector(SceneTextView.sendToGraveyard(_:)), to: nil, from: nil) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandGroup(before: .sidebar) {
                Button("Script") { model.viewMode = .script }.keyboardShortcut("1")
                Button("Corkboard") { model.viewMode = .cards }.keyboardShortcut("2")
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
}
