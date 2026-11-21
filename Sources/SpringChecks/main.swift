import Foundation
import SpringCore

func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if !cond { print("FAIL line \(line): \(msg)"); exit(1) }
}

// Fountain classification
let script = """
INT. BAR - NIGHT

Billy wipes a glass.

BILLY
We're shut.

SARAH
(sitting anyway)
Then talk to me.

CUT TO:

.FLASHBACK
ALL CAPS ACTION
continues here.
"""
let k = Fountain.classify(script)
check(k[0] == .heading, "heading")
check(k[2] == .action, "action")
check(k[4] == .character && k[5] == .dialogue, "cue + dialogue")
check(k[8] == .parenthetical && k[9] == .dialogue, "parenthetical")
check(k[11] == .transition, "transition")
check(k[13] == .heading, "forced heading")
check(k[14] == .action, "caps line after heading is action")
check(Fountain.headings(in: script) == ["INT. BAR - NIGHT", "FLASHBACK"], "headings")
check(Fountain.headingText("int. house - day #12#") == "INT. HOUSE - DAY", "scene number stripped")
check(!Fountain.isHeading("INTERIOR thoughts"), "INTERIOR is not a heading")
check(Fountain.isHeading("I/E CAR - MOVING"), "I/E heading")

// Frontmatter round trip and edits
var f = MarkdownFile(text: "---\ntitle: x\ntags: [draft]\nfoo:\n  bar: 1\n---\nINT. BAR - NIGHT\n")
check(f.body == "INT. BAR - NIGHT\n", "body split")
f.set("scene", "3")
f.ensureListItem("tags", "fountain")
f.ensureListItem("tags", "fountain")
check(f.text == "---\ntitle: x\ntags: [draft, fountain]\nfoo:\n  bar: 1\nscene: 3\n---\nINT. BAR - NIGHT\n", "inline tags + unknown keys kept: \(f.text)")
var g = MarkdownFile(text: "---\ntags:\n  - a\n---\nbody")
g.ensureListItem("tags", "fountain")
check(g.frontmatter == ["tags:", "  - a", "  - fountain"], "block tags")
var h = MarkdownFile(text: "no frontmatter")
h.ensureListItem("cssclasses", "fountain")
check(h.text == "---\ncssclasses:\n  - fountain\n---\nno frontmatter", "new frontmatter")
check(MarkdownFile(text: "---\nnot closed").frontmatter == nil, "unclosed fence is body")

// Project load order, save, rename and conflict guard
let dir = FileManager.default.temporaryDirectory.appending(path: "spring-check-\(UUID().uuidString)")
let scenesDir = dir.appending(path: "Scenes")
try FileManager.default.createDirectory(at: scenesDir, withIntermediateDirectories: true)
try "---\nscene: 2\n---\nEXT. HOUSE - DAY\n".write(to: scenesDir.appending(path: "a.md"), atomically: true, encoding: .utf8)
try "---\nscene: 1\n---\nINT. BAR - NIGHT\n".write(to: scenesDir.appending(path: "b.fountain.md"), atomically: true, encoding: .utf8)
try "ignored".write(to: scenesDir.appending(path: "image.png"), atomically: true, encoding: .utf8)
var scenes = try ProjectIO.loadScenes(in: dir)
check(scenes.map(\.heading) == ["INT. BAR - NIGHT", "EXT. HOUSE - DAY"], "order by scene property")

check(try ProjectIO.save(&scenes[1], number: 2, marker: .tag, rename: false) == .saved(renamedFrom: nil), "save without rename")
check(scenes[1].url.lastPathComponent == "a.md", "not renamed while typing")
if case .saved(let old) = try ProjectIO.save(&scenes[1], number: 2, marker: .tag) { check(old?.lastPathComponent == "a.md", "rename reports old name") } else { check(false, "save + rename") }
check(scenes[1].url.lastPathComponent == "EXT. HOUSE - DAY.md", "renamed after heading")
let saved = try String(contentsOf: scenes[1].url, encoding: .utf8)
check(saved == "---\nscene: 2\ntags:\n  - fountain\n---\nEXT. HOUSE - DAY\n", "md gets tag: \(saved)")

_ = try ProjectIO.save(&scenes[0], number: 1, marker: .tag)
let fm = try String(contentsOf: scenes[0].url, encoding: .utf8)
check(!fm.contains("fountain\n"), ".fountain.md gets no tag")

scenes[0].knownModDate = Date.distantPast
check(try ProjectIO.save(&scenes[0], number: 1, marker: .tag) == .conflict, "conflict when disk is newer")

// Links are rewritten after a rename
check(ProjectIO.rewriteLinks(in: "See [[a]], [[a|the house]], [[Scenes/a#Beat]], [[ab]] and [[a.fountain]].", from: "a", to: "EXT. HOUSE - DAY")
      == "See [[EXT. HOUSE - DAY]], [[EXT. HOUSE - DAY|the house]], [[Scenes/EXT. HOUSE - DAY#Beat]], [[ab]] and [[a.fountain]].", "link rewrite")
check(ProjectIO.linkName(of: URL(filePath: "/x/INT. BAR.fountain.md")) == "INT. BAR.fountain", "link name drops .md only")
let note = dir.appending(path: "Notes.md"), board = dir.appending(path: "Board.canvas")
try "Billy lives in [[old.fountain]].".write(to: note, atomically: true, encoding: .utf8)
try #"{"nodes":[{"type":"file","file":"p/Scenes/old.fountain"}]}"#.write(to: board, atomically: true, encoding: .utf8)
ProjectIO.updateLinks(under: dir, from: scenesDir.appending(path: "old.fountain"), to: scenesDir.appending(path: "INT. SHOP - DAY.fountain"))
check(try String(contentsOf: note, encoding: .utf8) == "Billy lives in [[INT. SHOP - DAY.fountain]].", "note link updated")
check(try String(contentsOf: board, encoding: .utf8).contains("Scenes/INT. SHOP - DAY.fountain\""), "canvas link updated")

// .fountain keeps its number in a hidden note
let plain = scenesDir.appending(path: "c.fountain")
try "[[scene: 7]]\nINT. SHOP - DAY\n".write(to: plain, atomically: true, encoding: .utf8)
var p = try ProjectIO.read(plain)
check(p.number == 7 && p.file.body == "INT. SHOP - DAY\n", "note read and hidden from the editor")
_ = try ProjectIO.save(&p, number: 4, marker: .tag, rename: false)
check(try String(contentsOf: plain, encoding: .utf8) == "[[scene: 4]]\nINT. SHOP - DAY\n", "note written back")

try? FileManager.default.removeItem(at: dir)
print("SpringChecks: all passed")
