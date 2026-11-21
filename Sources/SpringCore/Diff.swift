import Foundation

/// Line-by-line comparison (longest common subsequence), for comparing a snapshot with the current scene.
public enum LineDiff {
    public enum Change: Equatable, Sendable { case same(String), removed(String), added(String) }

    public static func compare(_ old: String, _ new: String) -> [Change] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        // ponytail: O(n·m) table; fine for scene-sized texts (a few hundred lines).
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Change] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { out.append(.same(a[i])); i += 1; j += 1 }
            else if i < a.count, j == b.count || lcs[i + 1][j] >= lcs[i][j + 1] { out.append(.removed(a[i])); i += 1 } // removals read first
            else { out.append(.added(b[j])); j += 1 }
        }
        return out
    }
}

extension Fountain {
    /// Line ranges of every speech by `name` (cue through its last line of dialogue).
    public static func speeches(by name: String, in text: String) -> [Range<Int>] {
        let lines = lines(text), kinds = classify(text)
        let target = name.uppercased()
        var out: [Range<Int>] = []
        var i = 0
        while i < lines.count {
            if kinds[i] == .character, Autocomplete.cueName(lines[i]) == target {
                var end = i + 1
                while end < lines.count, kinds[end] == .dialogue || kinds[end] == .parenthetical { end += 1 }
                out.append(i..<end)
                i = end
            } else { i += 1 }
        }
        return out
    }
}
