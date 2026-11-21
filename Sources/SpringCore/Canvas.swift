import Foundation

/// An Obsidian `.canvas` file (JSON Canvas, https://jsoncanvas.org) shown as columns of beat cards.
/// Groups are columns, ordered left to right; a card belongs to the group its centre sits in, ordered top to bottom.
/// Every key Spring doesn't use is kept, so the file round-trips through Obsidian untouched.
public struct CanvasBoard {
    public struct Card: Identifiable, Equatable {
        public let id: String
        public var text: String?
        public var file: String?
        public var color: String?
        /// First line of a text card, without Markdown heading marks.
        public var title: String {
            let first = (text ?? "").split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return first.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        }
        public var detail: String {
            let lines = (text ?? "").split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
            return lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
    }

    public struct Column: Identifiable, Equatable {
        public static let looseID = "loose"
        public let id: String
        public var label: String
        public var color: String?
        public var cards: [Card]
    }

    var root: [String: Any]

    public init() { root = ["nodes": [Any](), "edges": [Any]()] }

    public init(data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        root = obj
        if root["nodes"] == nil { root["nodes"] = [Any]() }
    }

    public var data: Data {
        (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    // MARK: Reading

    var nodes: [[String: Any]] {
        get { root["nodes"] as? [[String: Any]] ?? [] }
        set { root["nodes"] = newValue }
    }

    static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
    static func frame(_ n: [String: Any]) -> (x: Double, y: Double, w: Double, h: Double) {
        (num(n["x"]), num(n["y"]), num(n["width"]), num(n["height"]))
    }

    static func card(_ n: [String: Any]) -> Card {
        Card(id: n["id"] as? String ?? "", text: n["text"] as? String, file: n["file"] as? String, color: n["color"] as? String)
    }

    /// Index of the group containing the node's centre, if any.
    func groupIndex(of n: [String: Any], groups: [[String: Any]]) -> Int? {
        let f = Self.frame(n), cx = f.x + f.w / 2, cy = f.y + f.h / 2
        return groups.firstIndex { g in
            let r = Self.frame(g)
            return cx >= r.x && cx <= r.x + r.w && cy >= r.y && cy <= r.y + r.h
        }
    }

    var groups: [[String: Any]] {
        nodes.filter { $0["type"] as? String == "group" }.sorted { Self.num($0["x"]) < Self.num($1["x"]) }
    }

    public var columns: [Column] {
        let groups = self.groups
        var cols = groups.map { Column(id: $0["id"] as? String ?? "", label: $0["label"] as? String ?? "", color: $0["color"] as? String, cards: []) }
        var loose: [(Double, Card)] = []
        var placed: [[(Double, Card)]] = Array(repeating: [], count: groups.count)
        for n in nodes where ["text", "file", "link"].contains(n["type"] as? String ?? "") {
            let y = Self.num(n["y"])
            if let g = groupIndex(of: n, groups: groups) { placed[g].append((y, Self.card(n))) } else { loose.append((y, Self.card(n))) }
        }
        for i in cols.indices { cols[i].cards = placed[i].sorted { $0.0 < $1.0 }.map(\.1) }
        if !loose.isEmpty {
            cols.append(Column(id: Column.looseID, label: "Not in a group", cards: loose.sorted { $0.0 < $1.0 }.map(\.1)))
        }
        return cols
    }

    // MARK: Editing

    public static let cardWidth = 260.0, cardHeight = 120.0, gap = 20.0, padding = 20.0, columnGap = 60.0

    static func newID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased() }

    var contentMaxX: Double { nodes.map { Self.num($0["x"]) + Self.num($0["width"]) }.max() ?? 0 }
    var contentMinY: Double { nodes.map { Self.num($0["y"]) }.min() ?? 0 }

    /// Adds a group (column) to the right of everything else. Returns its id.
    @discardableResult
    public mutating func addColumn(_ label: String, color: String? = nil) -> String {
        let id = Self.newID()
        var g: [String: Any] = ["id": id, "type": "group", "label": label,
                                "x": nodes.isEmpty ? 0 : contentMaxX + Self.columnGap, "y": nodes.isEmpty ? 0 : contentMinY,
                                "width": Self.cardWidth + 2 * Self.padding, "height": Self.cardHeight + 2 * Self.padding]
        if let color { g["color"] = color }
        nodes.append(g)
        return id
    }

    /// Adds a text or file card at the bottom of a column. Returns its id.
    @discardableResult
    public mutating func addCard(text: String? = nil, file: String? = nil, to column: String) -> String {
        let id = Self.newID()
        var n: [String: Any] = ["id": id, "type": file == nil ? "text" : "file", "x": 0, "y": 0,
                                "width": Self.cardWidth, "height": Self.cardHeight]
        if let file { n["file"] = file } else { n["text"] = text ?? "" }
        let order = (columns.first { $0.id == column }?.cards.map(\.id) ?? []) + [id]
        nodes.append(n)
        restack(column, order: order)
        return id
    }

    public mutating func setText(_ id: String, _ text: String) {
        guard let i = nodes.firstIndex(where: { $0["id"] as? String == id }) else { return }
        nodes[i]["text"] = text
    }

    public mutating func remove(_ id: String) {
        nodes.removeAll { $0["id"] as? String == id }
        if var edges = root["edges"] as? [[String: Any]] {
            edges.removeAll { $0["fromNode"] as? String == id || $0["toNode"] as? String == id }
            root["edges"] = edges
        }
    }

    /// Moves a card into `column`, before `before` (or last), restacking both columns.
    public mutating func move(_ id: String, to column: String, before: String?) {
        let cols = columns
        guard let from = cols.first(where: { $0.cards.contains { $0.id == id } }), id != before else { return }
        var target = (cols.first { $0.id == column }?.cards.map(\.id) ?? []).filter { $0 != id }
        target.insert(id, at: before.flatMap { target.firstIndex(of: $0) } ?? target.endIndex)
        if from.id != column { restack(from.id, order: from.cards.map(\.id).filter { $0 != id }) }
        restack(column, order: target)
    }

    /// Lays the given cards out top to bottom inside the group, growing it to fit. Loose cards go right of everything.
    mutating func restack(_ column: String, order: [String]) {
        var x: Double, y: Double
        let gi = nodes.firstIndex { $0["id"] as? String == column && $0["type"] as? String == "group" }
        if let gi {
            let g = Self.frame(nodes[gi])
            x = g.x + Self.padding
            y = g.y + Self.padding
        } else {
            x = contentMaxX + Self.columnGap
            y = contentMinY
        }
        for id in order {
            guard let i = nodes.firstIndex(where: { $0["id"] as? String == id }) else { continue }
            nodes[i]["x"] = x
            nodes[i]["y"] = y
            y += Self.num(nodes[i]["height"]) + Self.gap
        }
        if let gi {
            let needed = y - Self.gap + Self.padding - Self.num(nodes[gi]["y"])
            nodes[gi]["height"] = max(needed, Self.cardHeight + 2 * Self.padding)
        }
    }

    public mutating func insert(_ template: BeatTemplate) {
        for act in template.acts {
            let col = addColumn(act.name, color: act.color)
            for beat in act.beats { addCard(text: "## \(beat)\n\n", to: col) }
        }
    }
}

public struct BeatTemplate: Identifiable, Sendable {
    public struct Act: Sendable { public let name: String; public let color: String?; public let beats: [String] }
    public var id: String { name }
    public let name: String
    public let acts: [Act]

    // JSON Canvas preset colours: 1 red, 2 orange, 3 yellow, 4 green, 5 cyan, 6 purple.
    public static let all: [BeatTemplate] = [
        BeatTemplate(name: "Three-act structure", acts: [
            Act(name: "Act One", color: "5", beats: ["Set-up", "Inciting incident", "Plot point one"]),
            Act(name: "Act Two", color: "4", beats: ["Rising action", "Midpoint", "Plot point two"]),
            Act(name: "Act Three", color: "6", beats: ["Climax", "Resolution"]),
        ]),
        BeatTemplate(name: "Save the Cat", acts: [
            Act(name: "Act One", color: "5", beats: ["Opening Image", "Theme Stated", "Set-up", "Catalyst", "Debate"]),
            Act(name: "Act Two A", color: "4", beats: ["Break into Two", "B Story", "Fun and Games", "Midpoint"]),
            Act(name: "Act Two B", color: "1", beats: ["Bad Guys Close In", "All Is Lost", "Dark Night of the Soul"]),
            Act(name: "Act Three", color: "6", beats: ["Break into Three", "Finale", "Final Image"]),
        ]),
        BeatTemplate(name: "Story Circle", acts: [
            Act(name: "Story Circle", color: "5", beats: ["You", "Need", "Go", "Search", "Find", "Take", "Return", "Change"]),
        ]),
        BeatTemplate(name: "Hero's Journey", acts: [
            Act(name: "Act One", color: "5", beats: ["Ordinary World", "Call to Adventure", "Refusal of the Call", "Meeting the Mentor", "Crossing the Threshold"]),
            Act(name: "Act Two", color: "4", beats: ["Tests, Allies, Enemies", "Approach to the Inmost Cave", "The Ordeal", "Reward"]),
            Act(name: "Act Three", color: "6", beats: ["The Road Back", "The Resurrection", "Return with the Elixir"]),
        ]),
    ]
}
