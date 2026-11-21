import AppKit
import SwiftUI

@main
struct SpringApp: App {
    // ponytail: no @State; Command Line Tools lack the SwiftUI macro plugin, and App is created once anyway.
    private let model = ProjectModel()

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
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { model.chooseProject() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveAll() }.keyboardShortcut("s")
            }
        }
    }
}
