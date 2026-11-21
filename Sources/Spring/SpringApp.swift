import AppKit
import Sparkle
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
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
                    .disabled(!canUpdate)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { model.chooseProject() }.keyboardShortcut("o")
            }
            CommandGroup(before: .sidebar) {
                Button("Script") { model.viewMode = .script }.keyboardShortcut("1")
                Button("Corkboard") { model.viewMode = .cards }.keyboardShortcut("2")
                Divider()
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveAll() }.keyboardShortcut("s")
            }
        }
    }
}
