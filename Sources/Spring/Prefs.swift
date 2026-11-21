import SpringCore
import SwiftUI

/// UserDefaults keys, shared by @AppStorage in views and plain reads in the model.
enum Prefs {
    static let saveFormat = "saveFormat"          // ".fountain.md" | ".md" | ".fountain" | ".txt"
    static let marker = "fountainMarker"          // "tag" | "cssclass"
    static let folders = "projectFolders"         // comma separated
    static let fontName = "scriptFont"
    static let fontSize = "fontSize"
    static let fadeSceneList = "fadeSceneList"
    static let vaultBookmark = "vaultBookmark"
    static let vaultPath = "vaultPath"            // shown in Settings only

    static var saveExt: String { UserDefaults.standard.string(forKey: saveFormat) ?? ".fountain.md" }
    static var fountainMarker: FountainMarker { FountainMarker(rawValue: UserDefaults.standard.string(forKey: marker) ?? "") ?? .tag }
    static var projectFolders: [String] {
        let raw = UserDefaults.standard.string(forKey: folders) ?? ProjectIO.defaultFolders.joined(separator: ", ")
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static let fonts = ["Courier Prime", "Space Mono", "Courier New"]
}

struct SettingsView: View {
    var body: some View {
        TabView {
            FilesSettings().tabItem { Label("Files", systemImage: "folder") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

struct FilesSettings: View {
    @AppStorage(Prefs.vaultPath) private var vaultPath = ""
    @AppStorage(Prefs.saveFormat) private var format = ".fountain.md"
    @AppStorage(Prefs.marker) private var marker = "tag"
    @AppStorage(Prefs.folders) private var folders = ProjectIO.defaultFolders.joined(separator: ", ")

    var body: some View {
        Form {
            LabeledContent("Obsidian vault:") {
                HStack {
                    Text(vaultPath.isEmpty ? "None" : (vaultPath as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(vaultPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { ProjectModel.chooseVault() }
                    if !vaultPath.isEmpty { Button("Clear") { ProjectModel.clearVault() } }
                }
            }
            Text("Optional. Lets Spring fix links across the whole vault and write vault paths in beat boards.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Save new scenes as:", selection: $format) {
                ForEach(ProjectIO.sceneExtensions, id: \.self) { Text($0) }
            }
            Picker("Mark .md scenes as Fountain with:", selection: $marker) {
                Text("Tag (tags: fountain)").tag("tag")
                Text("CSS class (cssclasses: fountain)").tag("cssclass")
            }
            .pickerStyle(.radioGroup)
            Text(".fountain.md needs no marker; .fountain and .txt stay plain.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("New project folders:", text: $folders)
            Text("Comma separated. Scenes is always created.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AppearanceSettings: View {
    @AppStorage(Prefs.fontName) private var fontName = "Courier Prime"
    @AppStorage(Prefs.fontSize) private var fontSize = 15.0
    @AppStorage(Prefs.fadeSceneList) private var fade = true

    var body: some View {
        Form {
            Picker("Script font:", selection: $fontName) {
                ForEach(Prefs.fonts, id: \.self) { Text($0).font(.custom($0, size: 13)) }
            }
            Slider(value: $fontSize, in: 12...20, step: 1) { Text("Size:") } minimumValueLabel: { Text("12") } maximumValueLabel: { Text("20") }
            Text("\(Int(fontSize)) pt").font(.caption).foregroundStyle(.secondary)
            Toggle("Fade the scene list until hovered", isOn: $fade)
        }
    }
}
