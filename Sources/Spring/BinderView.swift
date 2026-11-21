import SpringCore
import SwiftUI

/// The project's files: scenes in script order, then every other file and folder.
struct BinderView: View {
    @Environment(ProjectModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { selection }, set: { select($0) })) {
            Section {
                ForEach(Array(model.scenes.enumerated()), id: \.element.id) { i, scene in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                        Text(scene.heading).lineLimit(1).truncationMode(.tail)
                    }
                    .tag("s:" + scene.id.uuidString)
                    .contextMenu {
                        if Prefs.naming == .keep {
                            Button("Rename…") {
                                let stem = ProjectIO.stem(of: scene.url)
                                if let name = askForText("Rename scene file", initial: stem) { model.renameFile(scene.url, to: name) }
                            }
                        }
                        Button("Show in Finder") { reveal(scene.url) }
                        Divider()
                        Button("Send Scene to Graveyard") { model.buryScene(scene.id) }
                    }
                }
            } header: {
                HStack {
                    Text("Scenes")
                    Spacer()
                    Button { model.newScene() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New Scene (⌘N)")
                        .accessibilityLabel("New Scene")
                }
            }

            Section(model.projectURL?.lastPathComponent ?? "Project") {
                OutlineGroup(model.tree.filter { $0.url.lastPathComponent != "Scenes" }, children: \.children) { node in
                    HStack {
                        Label(node.name, systemImage: icon(for: node)).lineLimit(1)
                        Spacer()
                        if node.isFolder, let n = node.children?.count, n > 0 {
                            Text("\(n)").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }
                        .tag("f:" + node.url.path)
                        .contextMenu { menu(for: node) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: Theme.paper2))
    }

    private var selection: String? {
        if model.viewMode == .note, let url = model.note?.url { return "f:" + url.path }
        return nil
    }

    private func select(_ tag: String?) {
        guard let tag else { return }
        if tag.hasPrefix("s:"), let id = UUID(uuidString: String(tag.dropFirst(2))) {
            model.openInScript(id)
        } else if tag.hasPrefix("f:") {
            let url = URL(filePath: String(tag.dropFirst(2)))
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { model.openFile(url) }
        }
    }

    @ViewBuilder private func menu(for node: FileNode) -> some View {
        if node.isFolder {
            Button("New Note") { model.newNote(in: node.url) }
        }
        if !node.isFolder, node.url.deletingLastPathComponent().lastPathComponent == "Characters" {
            Button("Rename Character Everywhere…") { model.renameCharacter(file: node.url) }
        }
        if !node.isFolder {
            Button("Rename…") {
                if let name = askForText("Rename \(node.name)", initial: node.name) { model.renameFile(node.url, to: name) }
            }
        }
        Button("Show in Finder") { reveal(node.url) }
        if !node.isFolder { Button("Open in Obsidian") { model.openInObsidian(node.url) } }
        if !node.isFolder, node.url.deletingLastPathComponent().lastPathComponent != "Graveyard" {
            Divider()
            Button("Send to Graveyard") { model.buryFile(node.url) }
        }
    }

    private func icon(for node: FileNode) -> String {
        if node.isFolder {
            switch node.url.lastPathComponent {
            case "Characters": return "person.2"
            case "Locations": return "mappin.and.ellipse"
            case "Beats": return "square.grid.3x2"
            case "Research": return "books.vertical"
            case "Graveyard": return "archivebox"
            default: return "folder"
            }
        }
        return node.url.pathExtension.lowercased() == "canvas" ? "rectangle.connected.to.line.below" : "doc.text"
    }

    private func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

/// Plain editor for notes, characters, locations and the title page. Edits the raw file, frontmatter included.
struct NoteView: View {
    @Environment(ProjectModel.self) private var model

    var body: some View {
        if let note = model.note {
            VStack(spacing: 0) {
                if model.noteConflict {
                    HStack {
                        Text("\(note.url.lastPathComponent) changed on disk. Your edits are kept here until you choose.").font(.system(size: 12))
                        Spacer()
                        Button("Use disk version") { model.reloadNote() }
                        Button("Keep mine") { model.saveNote(force: true) }.buttonStyle(.borderedProminent)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.12))
                }
                TextEditor(text: Binding(get: { model.note?.file.body ?? "" }, set: { model.updateNote($0) }))
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: 680)
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(note.url.lastPathComponent)
            }
            .navigationSubtitle(note.url.lastPathComponent)
        }
    }
}
