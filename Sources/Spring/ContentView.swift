import SpringCore
import SwiftUI

struct ContentView: View {
    @Environment(ProjectModel.self) private var model
    @AppStorage(Prefs.fontSize) private var fontSize = 15.0
    @AppStorage(Prefs.fontName) private var fontName = "Courier Prime"
    @AppStorage(Prefs.typewriter) private var typewriter = false
    @AppStorage(Prefs.dim) private var dim = false
    @AppStorage(Prefs.accent) private var accent = "Ink blue" // re-renders when the accent changes

    var body: some View {
        Group {
            if model.projectURL == nil { WelcomeView() }
            else {
                NavigationSplitView(columnVisibility: Binding(get: { model.binder }, set: { model.binder = $0 })) {
                    BinderView().navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 380)
                } detail: {
                    switch model.viewMode {
                    case .cards: CorkboardView()
                    case .note: NoteView()
                    case .script: editor
                    }
                }
                .toolbar { toolbar }
            }
        }
        // No hard title bar: the toolbar sits on the page colour with no separator, as in the design.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .containerBackground(Color(nsColor: Theme.paper), for: .window)
        .navigationTitle("")
        .alert("Spring", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Text(model.projectURL?.lastPathComponent ?? "").fontWeight(.semibold).foregroundStyle(.primary)
                Text("·")
                Text(caption)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: Binding(get: { model.viewMode == .note ? .script : model.viewMode }, set: { model.viewMode = $0 })) {
                Label("Script", systemImage: "doc.text").tag(ProjectModel.ViewMode.script)
                Label("Corkboard", systemImage: "square.grid.2x2").tag(ProjectModel.ViewMode.cards)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Script or corkboard (⌘1 / ⌘2)")
            Button { model.continuous.toggle() } label: {
                Label(model.continuous ? "Single Scene" : "Continuous Script", systemImage: model.continuous ? "rectangle.stack" : "rectangle")
            }
            .help(model.continuous ? "Showing the whole script. Click for one scene at a time (⌘3)" : "Showing one scene. Click for the whole script (⌘3)")
            Menu {
                Button("PDF…") { model.exportPDF() }
                Button("Final Draft…") { model.export(as: "fdx") }
                Button("Word Document…") { model.export(as: "docx") }
                Button("Fountain…") { model.exportFountain() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .help("Export")
        }
    }

    private var caption: String {
        switch model.viewMode {
        case .script: return model.continuous ? "Script" : "Single scene"
        case .cards: return model.showBeats ? "Beats" : "Corkboard"
        case .note: return model.note?.url.deletingPathExtension().lastPathComponent ?? "Note"
        }
    }

    private var editor: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                if model.binder == .detailOnly { SceneList(proxy: proxy) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.scenes.enumerated()).filter { model.continuous || $0.element.id == model.currentScene }, id: \.element.id) { i, scene in
                            if i > 0 && model.continuous { SceneBreak(number: i + 1) }
                            if !model.continuous { SingleSceneHeader(index: i) }
                            if model.conflicts.contains(scene.id) { ConflictBanner(scene: scene) }
                            ScriptTextView(
                                text: Binding(get: { model.body(of: scene.id) }, set: { model.update(scene.id, body: $0) }),
                                fontName: fontName,
                                fontSize: fontSize,
                                sceneID: scene.id,
                                onEndEditing: { model.finishEditing(scene.id) },
                                onBeginEditing: { model.focusedScene = scene.id },
                                onBury: { model.bury($0, from: scene.id) },
                                onLeave: { model.leave(scene.id, up: $0) },
                                focusRequest: model.focusRequest,
                                typewriter: typewriter,
                                dim: dim,
                                suggest: { model.suggestions(for: $0, afterBlank: $1) }
                            )
                            .opacity(dim && model.focusedScene != nil && model.focusedScene != scene.id ? 0.35 : 1)
                            .animation(.easeOut(duration: 0.2), value: model.focusedScene)
                            .id(scene.id)
                        }
                        if model.scenes.isEmpty { EmptyScript() }
                    }
                    .frame(width: fontSize * 40)
                    .padding(.top, 56)
                    .padding(.bottom, typewriter ? 420 : 56)
                    .frame(maxWidth: .infinity)
                }
            }
            .overlay(alignment: .bottomTrailing) { StatusLine().padding(.trailing, 20).padding(.bottom, 14) }
            .overlay(alignment: .bottom) { ToastView().padding(.bottom, 20) }
            .onAppear { scroll(proxy) }
            .onChange(of: model.scrollTarget) { scroll(proxy) }
        }
        .background(Color(nsColor: Theme.paper))
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let id = model.scrollTarget else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top); model.scrollTarget = nil }
    }
}

/// Scene headings down the left, faded until the pointer is over them.
struct SceneList: View {
    @Environment(ProjectModel.self) private var model
    @AppStorage(Prefs.fadeSceneList) private var fade = true
    let proxy: ScrollViewProxy

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.scenes.enumerated()), id: \.element.id) { i, scene in
                    Button {
                        model.focus(scene.id, atEnd: false)
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(scene.id, anchor: .top) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                            Text(scene.heading).lineLimit(1).truncationMode(.tail)
                                .foregroundStyle(scene.id == model.focusedScene ? Color(nsColor: Theme.accent) : .primary)
                                .fontWeight(scene.id == model.focusedScene ? .semibold : .regular)
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 40)
            .padding(.horizontal, 12)
        }
        .frame(width: 260)
        .opacity(model.sceneListHovered || !fade ? 1 : 0.22)
        .animation(.easeOut(duration: 0.25), value: model.sceneListHovered)
        .onHover { model.sceneListHovered = $0 }
    }
}

struct SceneBreak: View {
    let number: Int
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().frame(height: 1)
            Text(String(format: "%03d", number)).font(.system(size: 10)).monospacedDigit()
            Rectangle().frame(height: 1)
        }
        .foregroundStyle(.quaternary)
        .padding(.vertical, 28)
        .accessibilityHidden(true)
    }
}

struct ConflictBanner: View {
    @Environment(ProjectModel.self) private var model
    let scene: SceneFile
    var body: some View {
        HStack {
            Text("\(scene.url.lastPathComponent) changed on disk. Your edits are kept here until you choose.")
                .font(.system(size: 12))
            Spacer()
            Button("Use disk version") { model.reload(scene.id) }
            Button("Keep mine") { model.keepMine(scene.id) }.buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 12)
    }
}

/// "Scene 2 of 6 · 1,284 words", faint, bottom right of the writing view.
struct StatusLine: View {
    @Environment(ProjectModel.self) private var model
    var body: some View {
        let index = model.focusedScene.flatMap { id in model.scenes.firstIndex { $0.id == id } }
        HStack(spacing: 14) {
            if let index { Text("Scene \(index + 1) of \(model.scenes.count)") } else { Text("\(model.scenes.count) scenes") }
            Text("\(model.wordCount.formatted()) words")
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .allowsHitTesting(false)
    }
}

/// Two panes, as in the design: actions and the Obsidian prompt on the left, recent projects on the right.
struct WelcomeView: View {
    @Environment(ProjectModel.self) private var model
    @AppStorage(Prefs.vaultPath) private var vaultPath = ""
    @AppStorage(Prefs.vaultPromptDone) private var promptDone = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spring").font(.custom("Courier Prime", size: 34).bold())
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(.bottom, 24)
                WelcomeAction(icon: "plus", title: "New project…", caption: "Creates Scenes, Characters, Locations and the rest") { model.newProject() }
                WelcomeAction(icon: "folder", title: "Open project folder…", caption: "Any folder, in or out of a vault") { model.chooseProject() }
                    .keyboardShortcut("o")
                Spacer()
                if vaultPath.isEmpty && !promptDone {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use with Obsidian?").font(.system(size: 13, weight: .semibold))
                        Text("Pick your vault to use its templates and keep links tidy. You can skip this and set it later in Settings.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Choose Vault…") { ProjectModel.chooseVault() }.buttonStyle(.borderedProminent)
                            Button("Skip") { promptDone = true }
                        }
                        .controlSize(.small)
                        .tint(Color(nsColor: Theme.accent))
                    }
                    .padding(14)
                    .background(Color(nsColor: Theme.paper2), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 48)
            .padding(.bottom, 28)
            .frame(width: 400, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: Theme.paper))

            VStack(alignment: .leading, spacing: 2) {
                Text("RECENT").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                let recents = model.recents
                if recents.isEmpty {
                    Text("Projects you open appear here.").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 10)
                }
                ForEach(recents, id: \.self) { url in
                    Button { model.openRecent(url) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                            Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(HoverRowStyle())
                }
                Spacer()
            }
            .padding(.top, 56)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: Theme.paper2))
            .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: Theme.line)).frame(width: 1) }
        }
        .ignoresSafeArea()
    }
}

struct WelcomeAction: View {
    let icon: String, title: String, caption: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Color(nsColor: Theme.accent)).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Text(caption).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(HoverRowStyle())
    }
}

/// A quiet row that tints on hover and press, like a sidebar row.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }
    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.0001), in: RoundedRectangle(cornerRadius: 8))
                .modifier(HoverTint())
        }
    }
}

/// Tints on hover without @State (the SwiftUI macro plugin isn't available in this toolchain): uses .onHover with an NSCursor-free overlay.
struct HoverTint: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(HoverOverlay().allowsHitTesting(false))
    }
}

/// AppKit tracking area, so hover works without SwiftUI @State.
struct HoverOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> HoverView { HoverView() }
    func updateNSView(_ nsView: HoverView, context: Context) {}
    final class HoverView: NSView {
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor }
        override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
        override func makeBackingLayer() -> CALayer { let l = CALayer(); l.cornerRadius = 8; return l }
        override var wantsUpdateLayer: Bool { true }
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
        required init?(coder: NSCoder) { fatalError() }
    }
}

/// Shown in the writing column when Scenes/ is empty.
struct EmptyScript: View {
    @Environment(ProjectModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("INT. ").font(.custom("Courier Prime", size: 15).bold()).foregroundStyle(.tertiary)
            Text("This project has no scenes yet.").font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("New Scene") { model.newScene() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(nsColor: Theme.accent))
                Text("⌘N").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Single-scene view: which scene this is, with previous and next.
struct SingleSceneHeader: View {
    @Environment(ProjectModel.self) private var model
    let index: Int
    var body: some View {
        HStack(spacing: 10) {
            Button { if index > 0 { model.focus(model.scenes[index - 1].id, atEnd: false) } } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0).help("Previous scene (⌘[)")
            Text("Scene \(index + 1) of \(model.scenes.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            Button { if index + 1 < model.scenes.count { model.focus(model.scenes[index + 1].id, atEnd: false) } } label: { Image(systemName: "chevron.right") }
                .disabled(index + 1 >= model.scenes.count).help("Next scene (⌘])")
        }
        .buttonStyle(.borderless)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
    }
}

/// "Moved to Graveyard/… · Undo", bottom centre, for a few seconds.
struct ToastView: View {
    @Environment(ProjectModel.self) private var model
    var body: some View {
        if let t = model.toast {
            HStack(spacing: 14) {
                Text(t.message).font(.system(size: 12))
                if let undo = t.undo {
                    Button("Undo") { undo(); model.toast = nil }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.66, green: 0.77, blue: 0.88))
                }
            }
            .foregroundStyle(Color(nsColor: Theme.paper))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.primary.opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}
