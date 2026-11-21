import AppKit
import Sparkle
import SwiftUI

@main
struct SpringApp: App {
    // ponytail: no @State; Command Line Tools lack the SwiftUI macro plugin, and App is created once anyway.
    private let model = ProjectModel()
    /// Only in a bundle that has a feed: `swift run` builds have no Info.plist, so Sparkle stays off.
    private let updater: SPUStandardUpdaterController? =
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

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
                if let updater {
                    Button("Check for Updates…") { updater.checkForUpdates(nil) }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { model.chooseProject() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveAll() }.keyboardShortcut("s")
            }
        }
    }
}
