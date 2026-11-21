import SpringCore
import SwiftUI

/// Index cards for every scene. Drag a card onto another to move it in front; drop on empty space to move it last.
/// Double-click opens the scene in the script.
struct CorkboardView: View {
    @Environment(ProjectModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 24)], spacing: 24) {
                    ForEach(Array(model.scenes.enumerated()), id: \.element.id) { i, scene in
                        SceneCard(number: i + 1, scene: scene)
                    }
                }
                .padding(32)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                withAnimation(.snappy) { model.move(id, before: nil) }
                return true
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onTapGesture { model.selected = nil }

            if let id = model.selected, let scene = model.scenes.first(where: { $0.id == id }) {
                Divider()
                SceneInspector(scene: scene).frame(width: 280)
            }
        }
    }
}

struct SceneCard: View {
    @Environment(ProjectModel.self) private var model
    let number: Int
    let scene: SceneFile

    private var isSelected: Bool { model.selected == scene.id }
    private var isDropTarget: Bool { model.dropTarget == scene.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(isSelected ? Color(nsColor: Theme.accent) : .secondary, in: RoundedRectangle(cornerRadius: 4))
            Text(scene.heading)
                .font(.custom("Courier Prime", size: 14).bold())
                .lineLimit(2)
            Text(scene.cardText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(5)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, maxHeight: 170, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color(nsColor: Theme.accent) : Color.primary.opacity(0.1), lineWidth: isSelected ? 1.5 : 1))
        .overlay(alignment: .leading) {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: Theme.accent)).frame(width: 3).offset(x: -14)
            }
        }
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.openInScript(scene.id) }
        .onTapGesture { model.selected = scene.id }
        .draggable(scene.id.uuidString) {
            Text(scene.heading).font(.custom("Courier Prime", size: 13).bold()).padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            withAnimation(.snappy) { model.move(id, before: scene.id) }
            model.dropTarget = nil
            return true
        } isTargeted: { model.dropTarget = $0 ? scene.id : (isDropTarget ? nil : model.dropTarget) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-click to open in the script. Drag to reorder.")
    }
}

struct SceneInspector: View {
    @Environment(ProjectModel.self) private var model
    let scene: SceneFile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PROPERTIES").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(scene.url.lastPathComponent).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
            if let fm = scene.file.frontmatter, !fm.isEmpty {
                Text(fm.joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Synopsis").font(.system(size: 13, weight: .semibold))
                TextEditor(text: Binding(get: { scene.explicitSynopsis }, set: { model.updateSynopsis(scene.id, $0) }))
                    .font(.system(size: 13))
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel("Synopsis")
            }
            Button("Open in Script") { model.openInScript(scene.id) }
            Spacer()
        }
        .padding(20)
        .background(Color(nsColor: Theme.paper))
    }
}
