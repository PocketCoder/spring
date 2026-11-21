import SpringCore
import SwiftUI

struct ContentView: View {
    @Environment(ProjectModel.self) private var model
    @AppStorage("fontSize") private var fontSize = 15.0

    var body: some View {
        Group {
            if model.projectURL == nil { WelcomeView() } else { editor }
        }
        .background(Color(nsColor: Theme.paper))
        .navigationTitle(model.projectURL?.lastPathComponent ?? "Spring")
        .alert("Spring", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var editor: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                SceneList(proxy: proxy)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.scenes.enumerated()), id: \.element.id) { i, scene in
                            if i > 0 { SceneBreak(number: i + 1) }
                            if model.conflicts.contains(scene.id) { ConflictBanner(scene: scene) }
                            ScriptTextView(
                                text: Binding(get: { model.body(of: scene.id) }, set: { model.update(scene.id, body: $0) }),
                                fontSize: fontSize,
                                onEndEditing: { model.finishEditing(scene.id) }
                            )
                            .id(scene.id)
                        }
                        if model.scenes.isEmpty {
                            Text("No scenes yet. Add .fountain.md files to the Scenes folder.").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: fontSize * 40)
                    .padding(.vertical, 56)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// Scene headings down the left, faded until the pointer is over them.
struct SceneList: View {
    @Environment(ProjectModel.self) private var model
    let proxy: ScrollViewProxy

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.scenes.enumerated()), id: \.element.id) { i, scene in
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(scene.id, anchor: .top) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                            Text(scene.heading).lineLimit(1).truncationMode(.tail)
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
        .opacity(model.sceneListHovered ? 1 : 0.22)
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

struct WelcomeView: View {
    @Environment(ProjectModel.self) private var model
    var body: some View {
        VStack(spacing: 16) {
            Text("Spring").font(.custom("Courier Prime", size: 34).bold())
            Button("Open Project Folder…") { model.chooseProject() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
