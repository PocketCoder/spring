import SpringCore
import SwiftUI

/// The beat board: Beats/Board.canvas shown as columns (groups) of cards. Changes are written back to the canvas,
/// so the same board opens in Obsidian.
struct BeatsView: View {
    @Environment(ProjectModel.self) private var model

    var body: some View {
        let columns = model.board?.columns ?? []
        HStack(spacing: 0) {
            if columns.isEmpty {
                VStack(spacing: 12) {
                    Text("No beat board yet").font(.title3)
                    Text("Start from a structure, or add a column and fill it yourself.").foregroundStyle(.secondary)
                    HStack {
                        BeatTemplateMenu()
                        Button("Add Column") { model.editBoard { $0.addColumn("Act One", color: "5") } }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 28) {
                        ForEach(columns) { BeatColumn(column: $0) }
                        Button { model.editBoard { $0.addColumn("New column") } } label: {
                            Label("Column", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 6)
                    }
                    .padding(32)
                }
                .onTapGesture { model.selectedCard = nil }
            }
            if let id = model.selectedCard, let card = columns.flatMap(\.cards).first(where: { $0.id == id }) {
                Divider()
                BeatInspector(card: card).frame(width: 280)
            }
        }
    }
}

struct BeatTemplateMenu: View {
    @Environment(ProjectModel.self) private var model
    var body: some View {
        Menu("Insert Beat Template") {
            ForEach(BeatTemplate.all) { t in
                Button("\(t.name) (\(t.acts.reduce(0) { $0 + $1.beats.count }) beats)") { model.editBoard { $0.insert(t) } }
            }
        }
        .fixedSize()
    }
}

/// JSON Canvas colours: "1"–"6" presets or a hex string.
func canvasColor(_ value: String?) -> Color {
    switch value {
    case "1": return .red
    case "2": return .orange
    case "3": return .yellow
    case "4": return .green
    case "5": return .teal
    case "6": return .purple
    case let hex? where hex.hasPrefix("#") && hex.count == 7:
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    default: return .secondary
    }
}

struct BeatColumn: View {
    @Environment(ProjectModel.self) private var model
    let column: CanvasBoard.Column

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(column.label.isEmpty ? "Untitled" : column.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(canvasColor(column.color))
            ForEach(column.cards) { BeatCard(card: $0, column: column.id) }
            HStack {
                Button { addText() } label: { Label("Card", systemImage: "plus") }
                Menu("Scene") {
                    ForEach(model.scenes) { scene in
                        Button(scene.heading) { model.editBoard { $0.addCard(file: model.vaultRelativePath(scene.url), to: column.id) } }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a card that links to a scene file")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: CanvasBoard.cardWidth + 28, alignment: .topLeading)
        .background(canvasColor(column.color).opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(canvasColor(column.color).opacity(0.35), lineWidth: 1.5))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }
            withAnimation(.snappy) { model.editBoard { $0.move(id, to: column.id, before: nil) } }
            return true
        }
    }

    private func addText() {
        var newID = ""
        model.editBoard { newID = $0.addCard(text: "## New beat\n\n", to: column.id) }
        model.selectedCard = newID
    }
}

struct BeatCard: View {
    @Environment(ProjectModel.self) private var model
    let card: CanvasBoard.Card
    let column: String

    var body: some View {
        let scene = card.file.flatMap(model.scene(forCardFile:))
        VStack(alignment: .leading, spacing: 4) {
            if let file = card.file {
                Label(scene?.heading ?? (file as NSString).lastPathComponent, systemImage: "doc.text")
                    .font(.custom("Courier Prime", size: 12).bold())
                    .foregroundStyle(Color(nsColor: Theme.accent))
                    .lineLimit(2)
                if let scene { Text(scene.cardText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3) }
            } else {
                Text(card.title.isEmpty ? "Untitled" : card.title).font(.system(size: 13, weight: .semibold))
                if !card.detail.isEmpty {
                    Text(card.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.selectedCard == card.id ? Color(nsColor: Theme.accent) : Color.primary.opacity(0.1),
                                                                lineWidth: model.selectedCard == card.id ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let scene { model.openInScript(scene.id) } }
        .onTapGesture { model.selectedCard = card.id }
        .draggable(card.id) { Text(card.title.isEmpty ? "Card" : card.title).padding(8).background(.background, in: RoundedRectangle(cornerRadius: 6)) }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }
            withAnimation(.snappy) { model.editBoard { $0.move(id, to: column, before: card.id) } }
            return true
        }
        .contextMenu {
            if let scene { Button("Open in Script") { model.openInScript(scene.id) } }
            Button("Delete Card", role: .destructive) { remove() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func remove() {
        if model.selectedCard == card.id { model.selectedCard = nil }
        model.editBoard { $0.remove(card.id) }
    }
}

struct BeatInspector: View {
    @Environment(ProjectModel.self) private var model
    let card: CanvasBoard.Card

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("BEAT").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if let file = card.file {
                Text(file).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                if let scene = model.scene(forCardFile: file) {
                    Button("Open in Script") { model.openInScript(scene.id) }
                } else {
                    Text("No scene in this project matches this path.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("First line is the title. Markdown, as in Obsidian.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { card.text ?? "" }, set: { t in model.editBoard { $0.setText(card.id, t) } }))
                    .font(.system(size: 13))
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel("Beat text")
            }
            Button("Delete Card", role: .destructive) {
                model.selectedCard = nil
                model.editBoard { $0.remove(card.id) }
            }
            Spacer()
        }
        .padding(20)
        .background(Color(nsColor: Theme.paper))
    }
}
