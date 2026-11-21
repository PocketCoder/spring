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

// Synopsis: property for markdown, Fountain "=" line otherwise
var md = SceneFile(url: URL(filePath: "/x/s.fountain.md"), file: MarkdownFile(text: "---\nscene: 1\n---\nINT. BAR - NIGHT\n\nBilly waits.\n"))
check(md.cardText == "Billy waits.", "card falls back to first action")
md.setSynopsis("Sarah: \"we need to talk\"")
check(md.file.value("synopsis") == "Sarah: \"we need to talk\"", "quoted synopsis round trip: \(md.file.text)")
check(md.cardText == "Sarah: \"we need to talk\"", "card shows synopsis")
var fo = SceneFile(url: URL(filePath: "/x/s.fountain"), file: MarkdownFile(text: "INT. BAR - NIGHT\n\nBilly waits.\n"))
fo.setSynopsis("Closing time.")
check(fo.file.body == "INT. BAR - NIGHT\n= Closing time.\n\nBilly waits.\n", "fountain synopsis line: \(fo.file.body)")
fo.setSynopsis("Last orders.")
check(fo.explicitSynopsis == "Last orders." && fo.file.body.components(separatedBy: "= ").count == 2, "synopsis replaced")
fo.setSynopsis("")
check(fo.file.body == "INT. BAR - NIGHT\n\nBilly waits.\n", "synopsis removed")

// New project, new scene and the Graveyard
let proj = dir.appending(path: "new-project")
try ProjectIO.createProject(at: proj)
for f in ProjectIO.defaultFolders { check(FileManager.default.fileExists(atPath: proj.appending(path: f).path), "folder \(f)") }
check(try String(contentsOf: proj.appending(path: "front-matter.md"), encoding: .utf8).hasPrefix("Title: new-project\n"), "title page")
try "mine".write(to: proj.appending(path: "Logline.md"), atomically: true, encoding: .utf8)
try ProjectIO.createProject(at: proj)
check(try String(contentsOf: proj.appending(path: "Logline.md"), encoding: .utf8) == "mine", "createProject never overwrites")
let s1 = try ProjectIO.newScene(in: proj, ext: ".fountain.md")
let s2 = try ProjectIO.newScene(in: proj, ext: ".fountain.md")
check(s1.url.lastPathComponent == "Untitled scene.fountain.md" && s2.url.lastPathComponent == "Untitled scene 2.fountain.md", "new scenes don't collide")
var bar = SceneFile(url: proj.appending(path: "Scenes/INT. BAR - NIGHT.fountain.md"), file: MarkdownFile(text: "INT. BAR - NIGHT\n"))
let grave = try ProjectIO.bury("He puts the glass down.\n", from: bar, in: proj, date: Date(timeIntervalSince1970: 0))
try ProjectIO.bury("Second cut.", from: bar, in: proj, date: Date(timeIntervalSince1970: 0))
let gtext = try String(contentsOf: grave, encoding: .utf8)
check(grave.lastPathComponent == "INT. BAR - NIGHT.md" && gtext.contains("from [[INT. BAR - NIGHT.fountain]]\n\nHe puts the glass down.\n\n") && gtext.contains("Second cut."), "selection buried: \(gtext)")
let moved = try ProjectIO.bury(file: s1.url, in: proj)
let _ = try ProjectIO.newScene(in: proj, ext: ".fountain.md")
let moved2 = try ProjectIO.bury(file: proj.appending(path: "Scenes/Untitled scene.fountain.md"), in: proj)
check(moved.path.contains("/Graveyard/Untitled scene.fountain.md") && moved2.lastPathComponent == "Untitled scene 2.fountain.md", "file buried without overwriting")
_ = bar

// Binder tree and plain notes
try "Billy".write(to: proj.appending(path: "Characters/BILLY (M24) - Shopkeeper.md"), atomically: true, encoding: .utf8)
try "x".write(to: proj.appending(path: "Characters/photo.png"), atomically: true, encoding: .utf8)
let tree = ProjectIO.tree(at: proj)
check(tree.prefix(2).map(\.name) == ["front-matter", "Logline"], "files first: \(tree.map(\.name))")
check(tree.dropFirst(2).map(\.name).prefix(3) == ["Scenes", "Characters", "Locations"], "folders in project order")
let chars = tree.first { $0.name == "Characters" }?.children ?? []
check(chars.map(\.name) == ["BILLY (M24) - Shopkeeper"] && chars[0].children == nil, "only text files, no arrow on files")
let noteURL = try ProjectIO.newNote(in: proj.appending(path: "Notes"))
var raw = try ProjectIO.readRaw(noteURL)
raw.file.body = "---\ntags: [x]\n---\nIdea"
check(try ProjectIO.write(&raw) == .saved(renamedFrom: nil), "note saved")
check(try String(contentsOf: noteURL, encoding: .utf8) == "---\ntags: [x]\n---\nIdea", "raw text written as is")
check(try ProjectIO.newNote(in: proj.appending(path: "Notes")).lastPathComponent == "Untitled 2.md", "new note numbered")

// Beats beats (.canvas)
var beats = CanvasBoard()
beats.insert(BeatTemplate.all[1])
var cols = beats.columns
check(cols.map(\.label) == ["Act One", "Act Two A", "Act Two B", "Act Three"], "template columns")
check(cols.map { $0.cards.count } == [5, 4, 3, 3], "save the cat has 15 beats")
check(cols[0].cards.map(\.title) == ["Opening Image", "Theme Stated", "Set-up", "Catalyst", "Debate"], "cards in order")
let catalyst = cols[0].cards[3].id
beats.move(catalyst, to: cols[1].id, before: cols[1].cards[0].id)
cols = beats.columns
check(cols[0].cards.count == 4 && cols[1].cards.first?.title == "Catalyst", "move between columns")
beats.move(catalyst, to: cols[1].id, before: nil)
check(beats.columns[1].cards.last?.title == "Catalyst", "move to end")
let fileCard = beats.addCard(file: "my-project/Scenes/INT. BAR - NIGHT.fountain.md", to: cols[3].id)
check(beats.columns[3].cards.last?.file == "my-project/Scenes/INT. BAR - NIGHT.fountain.md", "file card")
beats.setText(cols[2].cards[0].id, "## Bad Guys Close In\n\nThe landlord calls.")
check(beats.columns[2].cards[0].detail == "The landlord calls.", "card detail")
beats.remove(fileCard)
check(beats.columns[3].cards.count == 3, "card removed")
// Round trip keeps unknown keys and Obsidian-made layouts
let obsidian = ###"{"nodes":[{"id":"g","type":"group","label":"Act One","x":0,"y":0,"width":400,"height":600,"custom":true},{"id":"a","type":"text","text":"## B","x":20,"y":300,"width":200,"height":100},{"id":"b","type":"text","text":"## A","x":20,"y":20,"width":200,"height":100},{"id":"c","type":"text","text":"loose","x":900,"y":0,"width":200,"height":100}],"edges":[{"id":"e","fromNode":"a","toNode":"b"}],"extra":1}"###
var ob = try CanvasBoard(data: Data(obsidian.utf8))
check(ob.columns.map(\.label) == ["Act One", "Not in a group"] && ob.columns[0].cards.map(\.title) == ["A", "B"], "Obsidian layout read by position")
ob.remove("a")
let again = try JSONSerialization.jsonObject(with: ob.data) as! [String: Any]
check(again["extra"] as? Int == 1 && ((again["nodes"] as! [[String: Any]])[0]["custom"] as? Bool) == true, "unknown keys kept")
check((again["edges"] as! [Any]).isEmpty, "edges to removed card dropped")

// Autocomplete
check(Autocomplete.characterName(fromFileStem: "BILLY (M24) - Shopkeeper") == "BILLY", "name from file")
check(Autocomplete.characterName(fromFileStem: "Mrs Hale - Landlady") == "MRS HALE", "name without age")
let names = Autocomplete.characters(fileStems: ["BILLY (M24) - Shopkeeper", "SARAH (F55) - Mum"], sceneBodies: ["INT. BAR\n\nBARMAN (V.O.)\nLast orders.\n\nSARAH\nNo."])
check(names == ["BARMAN", "BILLY", "SARAH"], "cues from files and scenes: \(names)")
let places = Autocomplete.locations(fileStems: ["Bar", "House"], sceneBodies: ["INT. HOUSE - KITCHEN - DAY\n\nEXT. BUS STOP - NIGHT"])
check(places == ["BAR", "BUS STOP", "HOUSE", "HOUSE - KITCHEN"], "locations: \(places)")
check(Autocomplete.suggestions(for: "B", afterBlank: true, characters: names, locations: places) == ["BARMAN", "BILLY"], "cue suggestions")
check(Autocomplete.suggestions(for: "B", afterBlank: false, characters: names, locations: places).isEmpty, "no cue mid-action")
check(Autocomplete.suggestions(for: "Billy", afterBlank: true, characters: names, locations: places).isEmpty, "mixed case is action")
check(Autocomplete.suggestions(for: "IN", afterBlank: true, characters: ["INGRID"], locations: places).isEmpty, "INT. beats a cue")
check(Autocomplete.suggestions(for: "INT. HO", afterBlank: true, characters: names, locations: places) == ["INT. HOUSE", "INT. HOUSE - KITCHEN"], "heading locations")
check(Autocomplete.suggestions(for: "ext. b", afterBlank: true, characters: names, locations: places) == ["ext. BAR", "ext. BUS STOP"], "keeps typed prefix")
check(Autocomplete.suggestions(for: "INT. BAR - N", afterBlank: true, characters: names, locations: places) == ["INT. BAR - NIGHT"], "time of day")
check(Autocomplete.suggestions(for: "INT. HOUSE - K", afterBlank: true, characters: names, locations: places) == ["INT. HOUSE - KITCHEN"], "sub-location after a dash")
check(Autocomplete.suggestions(for: "SARAH (", afterBlank: true, characters: names, locations: places) == ["SARAH (V.O.)", "SARAH (O.S.)", "SARAH (CONT'D)"], "extensions")

// Sync with changes made outside Spring
let sp = dir.appending(path: "sync-project")
try ProjectIO.createProject(at: sp, folders: ["Scenes"])
let sd = sp.appending(path: "Scenes")
try "---\nscene: 1\n---\nINT. A\n".write(to: sd.appending(path: "a.fountain.md"), atomically: true, encoding: .utf8)
try "---\nscene: 2\n---\nINT. B\n".write(to: sd.appending(path: "b.fountain.md"), atomically: true, encoding: .utf8)
var live = try ProjectIO.loadScenes(in: sp)
let future = Date().addingTimeInterval(60)
func touch(_ name: String, _ text: String) throws {
    try text.write(to: sd.appending(path: name), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: sd.appending(path: name).path)
}
var r = ProjectIO.sync(live, dirty: [], conflicts: [], in: sp)
check(!r.changed && r.scenes.map(\.heading) == ["INT. A", "INT. B"], "no change, no reload")
try touch("a.fountain.md", "---\nscene: 1\n---\nINT. A EDITED\n")
r = ProjectIO.sync(live, dirty: [], conflicts: [], in: sp)
check(r.changed && r.scenes[0].heading == "INT. A EDITED" && r.scenes[0].id == live[0].id, "clean scene reloaded in place")
r = ProjectIO.sync(live, dirty: [live[0].id], conflicts: [], in: sp)
check(r.conflicts == [live[0].id] && r.scenes[0].heading == "INT. A", "dirty scene becomes a conflict, edits kept")
live = ProjectIO.sync(live, dirty: [], conflicts: [], in: sp).scenes
try "---\nscene: 3\n---\nINT. C\n".write(to: sd.appending(path: "c.fountain.md"), atomically: true, encoding: .utf8)
try FileManager.default.removeItem(at: sd.appending(path: "b.fountain.md"))
r = ProjectIO.sync(live, dirty: [], conflicts: [], in: sp)
check(r.scenes.map(\.heading) == ["INT. A EDITED", "INT. C"], "new file added, deleted file dropped: \(r.scenes.map(\.heading))")
r = ProjectIO.sync(live, dirty: [live[1].id], conflicts: [], in: sp)
check(r.scenes.contains { $0.id == live[1].id } && r.conflicts.contains(live[1].id), "deleted while dirty is kept as a conflict")

// Screenplay layout (PDF export)
typealias SP = Screenplay
check(SP.runs("a **b** *c* ***d*** _e_ \\*f") == [SP.Run("a "), SP.Run("b", bold: true), SP.Run(" "), SP.Run("c", italic: true), SP.Run(" "),
      SP.Run("d", bold: true, italic: true), SP.Run(" "), SP.Run("e", underline: true), SP.Run(" *f")], "emphasis: \(SP.runs("a **b** *c* ***d*** _e_ \\*f"))")
let wrapped = SP.wrap(SP.runs("one two **three** four"), width: 9)
check(wrapped.map { $0.map(\.text).joined() } == ["one two", "three", "four"] && wrapped[1] == [SP.Run("three", bold: true)], "wrap keeps styles")
check(SP.wrap([SP.Run(String(repeating: "x", count: 25))], width: 10).count == 3, "long words broken")

let scene = """
INT. BAR - NIGHT #4#
= A synopsis that never prints.
[[A note that never prints.]]

Billy wipes a glass. /* cut this */

BILLY
(quietly)
We're shut.

CUT TO:

> THE END <
"""
let pages = SP.paginate([scene], options: SP.Options(sceneNumbers: true))
let text = pages[0].map { $0?.text ?? "" }
check(text == ["INT. BAR - NIGHT", "", "Billy wipes a glass.", "", "BILLY", "(quietly)", "We're shut.", "", "CUT TO:", "", "THE END"], "page text: \(text)")
let lines = pages[0].compactMap { $0 }
check(lines[0].sceneNumber == "4" && lines[0].runs[0].bold, "explicit scene number kept, heading bold")
check(lines[2].indent == 22 && lines[3].indent == 16 && lines[4].indent == 10, "cue, parenthetical, dialogue indents")
check(lines[5].align == .right && lines[6].align == .center, "transition right, centred text centred")

// Dialogue across a page: (MORE) at the bottom, (CONT'D) at the top
let filler = Array(repeating: "Action line.", count: 6).joined(separator: "\n\n")
let speech = (1...8).map { "Line \($0) of the speech." }.joined(separator: "\n")
let long = SP.paginate(["INT. A - DAY\n\n\(filler)\n\nSARAH\n\(speech)"], options: SP.Options(linesPerPage: 20))
let p1 = long[0].map { $0?.text ?? "" }, p2 = long[1].map { $0?.text ?? "" }
check(p1.count <= 20 && p1.last == "(MORE)" && p2.first == "SARAH (CONT'D)", "MORE / CONT'D: \(p1) | \(p2)")
check((p1 + p2).filter { $0.hasPrefix("Line ") }.count == 8, "no dialogue lost across the break")
let wordy = (1...6).map { "Sentence \($0) runs on and on across more than one line of dialogue here." }.joined(separator: " ")
let broken = SP.paginate(["INT. A - DAY\n\n\(filler)\n\nSARAH\n\(wordy)"], options: SP.Options(linesPerPage: 20))
for page in broken where page.last??.text == "(MORE)" {
    let before = page.compactMap { $0 }.dropLast().last?.text ?? ""
    check(before.hasSuffix("."), "speech breaks only after a sentence ends: \(before)")
}
check(broken.flatMap { $0 }.compactMap { $0?.text }.joined(separator: " ").contains("Sentence 6 runs"), "whole speech printed")

// A heading never ends a page
let crowd = Array(repeating: "Action.", count: 9).joined(separator: "\n\n")
let kept = SP.paginate(["INT. A - DAY\n\n\(crowd)\n\nINT. B - DAY\n\nMore action."], options: SP.Options(linesPerPage: 20))
check(kept[0].compactMap { $0 }.last?.text != "INT. B - DAY" && kept[1].first??.text == "INT. B - DAY", "heading moved to the next page")
check(SP.paginate(["INT. A\n\nOne.\n\n===\n\nTwo."]).count == 2, "forced page break")

let tp = SP.titlePage("Title: My Project\nCredit: Written by\nAuthor: Jo Bloggs\nDraft date: 21 November 2026\nContact:\n    jo@example.com\n    01234 567890")
check(tp.centre.map(\.text) == ["MY PROJECT", "", "Written by", "", "Jo Bloggs"], "title page centre: \(tp.centre.map(\.text))")
check(tp.bottomLeft.map(\.text) == ["21 November 2026", "", "jo@example.com", "01234 567890"], "title page contact: \(tp.bottomLeft.map(\.text))")

// Obsidian templates
let vault = dir.appending(path: "vault")
try FileManager.default.createDirectory(at: vault.appending(path: ".obsidian/plugins/templater-obsidian"), withIntermediateDirectories: true)
check(Templates.folder(inVault: vault) == nil, "no templates configured")
try #"{"templates_folder": "Meta/Templater"}"#.write(to: vault.appending(path: ".obsidian/plugins/templater-obsidian/data.json"), atomically: true, encoding: .utf8)
check(Templates.folder(inVault: vault)?.path.hasSuffix("Meta/Templater") == true, "Templater folder")
try #"{"folder": "/Templates/"}"#.write(to: vault.appending(path: ".obsidian/templates.json"), atomically: true, encoding: .utf8)
check(Templates.folder(inVault: vault)?.lastPathComponent == "Templates", "core Templates folder wins, slashes trimmed")
try FileManager.default.createDirectory(at: vault.appending(path: "Templates"), withIntermediateDirectories: true)
for n in ["Scene.md", "Character.md", "image.png"] { try "".write(to: vault.appending(path: "Templates/\(n)"), atomically: true, encoding: .utf8) }
check(Templates.list(in: vault.appending(path: "Templates")) == ["Character.md", "Scene.md"], "template list")
var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
let when = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 14, minute: 5))!
check(Templates.render("# {{title}}\nCreated {{date}} {{time}}\n<% tp.file.title %>", title: "BILLY", date: when)
      == "# BILLY\nCreated 2026-11-03 14:05\n<% tp.file.title %>", "core placeholders, Templater untouched")
check(Templates.render("{{date:dddd D MMMM YYYY}} [{{ time:h:mm A }}]", title: "", date: when) == "Tuesday 3 November 2026 [2:05 PM]", "moment formats: \(Templates.render("{{date:dddd D MMMM YYYY}} [{{ time:h:mm A }}]", title: "", date: when))")
check(Templates.formatted(when, moment: "[Week of] YYYY-MM-DD") == "Week of 2026-11-03", "bracketed literal")

// Dual dialogue side by side
let duet = SP.paginate(["INT. A - DAY\n\nBRICK\nScrew retirement.\n\nSTEEL ^\n(laughing)\nScrew retirement.\n\nThey drink."])[0].compactMap { $0 }
check(duet[1].text == "BRICK" && duet[1].rightText == "STEEL" && duet[1].indent == 8 && duet[1].rightIndent == 39, "cues side by side: \(duet.map { $0.text + " | " + $0.rightText })")
check(duet[2].text == "Screw retirement." && duet[2].rightText == "(laughing)" && duet[3].text.isEmpty && duet[3].rightText == "Screw retirement.", "columns run independently")
check(duet.last?.text == "They drink.", "action after the duet")
let solo = SP.paginate(["INT. A - DAY\n\nSTEEL ^\nAlone."])[0].compactMap { $0 }
check(solo[1].text == "STEEL" && solo[1].rightText.isEmpty, "^ with no speech before it prints normally")

let duetText = "INT. A\n\nBRICK\nScrew it.\n\nSTEEL ^\n(laughing)\nScrew it.\n\nThey drink.\n\nSTEEL ^\nAlone."
let pairs = Fountain.dualPairs(duetText)
check(pairs.count == 1 && pairs[0].left == 2..<5 && pairs[0].right == 5..<8, "dual pair line ranges: \(pairs)")

// Final Draft export
let fdx = FDX.document(scripts: ["INT. BAR - NIGHT #4A#\n\nBilly & **Sarah** wait.\n\nBILLY\n(quietly)\nShut.\n\nSARAH ^\nNo.\n\n===\n\nCUT TO:"], titlePage: "Title: Bar <One>")
check(fdx.contains("<Paragraph Type=\"Scene Heading\" Number=\"4A\"><Text>INT. BAR - NIGHT</Text></Paragraph>"), "fdx heading")
check(fdx.contains("<Text>Billy &amp; </Text><Text Style=\"Bold\">Sarah</Text><Text> wait.</Text>"), "fdx escaping and styles")
check(fdx.contains("<DualDialogue>") && fdx.contains("<Paragraph Type=\"Parenthetical\"><Text>(quietly)</Text></Paragraph>"), "fdx dual dialogue")
check(fdx.contains("<Paragraph Type=\"Transition\" StartsNewPage=\"Yes\"><Text>CUT TO:</Text></Paragraph>"), "fdx page break")
check(fdx.contains("<Text>BAR &lt;ONE&gt;</Text>"), "fdx title page")
check((try? XMLDocument(xmlString: fdx)) != nil, "fdx is well-formed XML")

// Scene naming
let nameScene = SceneFile(url: URL(filePath: "/nonexistent/Scenes/x.fountain.md"), file: MarkdownFile(text: "INT. BAR - NIGHT\n"))
check(ProjectIO.targetURL(for: nameScene, number: 3, naming: .numbered).lastPathComponent == "003 INT. BAR - NIGHT.fountain.md", "numbered name")
check(ProjectIO.targetURL(for: nameScene, number: 3, naming: .keep).lastPathComponent == "x.fountain.md", "keep name")
check(ProjectIO.targetURL(for: nameScene, number: 3, naming: .heading).lastPathComponent == "INT. BAR - NIGHT.fountain.md", "heading name")

// Colour labels and board editing
var labelled = SceneFile(url: URL(filePath: "/x/a.fountain.md"), file: MarkdownFile(text: "---\nscene: 1\n---\nINT. A\n"))
labelled.setColorLabel("green")
check(labelled.colorLabel == "green" && labelled.file.text.contains("color: green"), "colour label set")
labelled.setColorLabel(nil)
check(labelled.colorLabel == nil && !labelled.file.text.contains("color"), "colour label cleared")
check(!SceneFile(url: URL(filePath: "/x/a.fountain"), file: MarkdownFile(text: "INT. A")).canLabel, "plain .fountain can't hold a label")
var ob2 = try CanvasBoard(data: Data(obsidian.utf8))
ob2.renameColumn("g", "Act 1"); ob2.setColor("g", "4")
check(ob2.columns[0].label == "Act 1" && ob2.columns[0].color == "4", "rename and recolour column")
check(ob2.links(from: "a") == ["A"], "arrow targets: \(ob2.links(from: "a"))")
ob2.removeColumn("g")
check(ob2.columns.map(\.label) == ["Not in a group"] && ob2.columns[0].cards.count == 3, "removing a column keeps its cards")

// Markdown-style links and renaming
check(ProjectIO.rewriteMarkdownLinks(in: "[a](INT.%20BAR.md) [b](Scenes/INT.%20BAR.md#top) [c](<INT. BAR.md>) [d](INT.%20BARN.md)", from: "INT. BAR.md", to: "INT. PUB.md")
      == "[a](INT.%20PUB.md) [b](Scenes/INT.%20PUB.md#top) [c](<INT. PUB.md>) [d](INT.%20BARN.md)", "markdown links: \(ProjectIO.rewriteMarkdownLinks(in: "[a](INT.%20BAR.md) [b](Scenes/INT.%20BAR.md#top) [c](<INT. BAR.md>) [d](INT.%20BARN.md)", from: "INT. BAR.md", to: "INT. PUB.md"))")
let renamed = try ProjectIO.rename(proj.appending(path: "Notes/Untitled.md"), to: "Ideas")
check(renamed.lastPathComponent == "Ideas.md" && FileManager.default.fileExists(atPath: renamed.path), "rename keeps extension")

// Nothing is cut, however long
let wall = (1...80).map { "Line \($0) of one enormous centred thing." }.joined(separator: " ")
let tall = SP.paginate(["> \(wall) <", "INT. A\n\nAfter."], options: SP.Options(linesPerPage: 20))
check(tall.flatMap { $0 }.compactMap { $0 }.count > 20 && tall.last?.compactMap { $0 }.last?.text == "After.", "tall block carried over, not cut")

// Word export
check(Zip.crc32(Data("123456789".utf8)) == 0xCBF4_3926, "crc32")
let docx = DOCX.document(scripts: ["INT. BAR - NIGHT\n\nBilly & Sarah.\n\nBILLY\n(quiet)\nShut.\n\nSARAH ^\nNo.\n\n===\n\nCUT TO:"], titlePage: "Title: Bar", pageSize: (595.28, 841.89))
check(docx.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]), "docx is a zip")
let docXML = String(decoding: docx, as: UTF8.self)
check(docXML.contains("word/document.xml") && docXML.contains("<w:keepNext/>") && docXML.contains("<w:tbl>") && docXML.contains("<w:pageBreakBefore/>"), "docx keeps headings with next, dual table, page break")
check(docXML.contains("Billy &amp; Sarah.") && docXML.contains(#"w:left="2160""#), "docx escaping and margins")

try? FileManager.default.removeItem(at: dir)
print("SpringChecks: all passed")
