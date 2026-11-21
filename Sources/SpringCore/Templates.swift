import Foundation

/// Obsidian templates: finds the vault's templates folder and fills in core Templates placeholders
/// (`{{title}}`, `{{date}}`, `{{time}}`, `{{date:YYYY-MM-DD}}`). Templater's `<% %>` is left as written.
public enum Templates {
    /// The templates folder the vault is set up with: core Templates first, then Templater.
    public static func folder(inVault vault: URL) -> URL? {
        let candidates: [(String, String)] = [
            (".obsidian/templates.json", "folder"),
            (".obsidian/plugins/templater-obsidian/data.json", "templates_folder"),
        ]
        for (file, key) in candidates {
            guard let data = try? Data(contentsOf: vault.appending(path: file)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = (json[key] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), !path.isEmpty
            else { continue }
            return vault.appending(path: path, directoryHint: .isDirectory)
        }
        return nil
    }

    public static func list(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func render(_ template: String, title: String, date: Date = .now) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\{\{\s*(title|date|time)\s*(?::([^}]*))?\}\}"#, options: .caseInsensitive) else { return template }
        let ns = template as NSString
        var out = "", last = 0
        for m in re.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            let format = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            switch name {
            case "title": out += title
            case "date": out += formatted(date, moment: format ?? "YYYY-MM-DD")
            default: out += formatted(date, moment: format ?? "HH:mm")
            }
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// Moment.js format (as Obsidian uses) to a formatted date. Text in [brackets] is literal.
    public static func formatted(_ date: Date, moment: String) -> String {
        let tokens: [(String, String)] = [
            ("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
            ("DDDD", "DDD"), ("DD", "dd"), ("Do", "d"), ("D", "d"), ("dddd", "EEEE"), ("ddd", "EEE"),
            ("HH", "HH"), ("H", "H"), ("hh", "hh"), ("h", "h"), ("mm", "mm"), ("m", "m"), ("ss", "ss"), ("s", "s"),
            ("A", "a"), ("a", "a"),
        ]
        var icu = ""
        var upperAmPm = false // moment: A gives "PM", a gives "pm"
        var rest = Substring(moment)
        while !rest.isEmpty {
            if rest.first == "[", let close = rest.firstIndex(of: "]") {
                icu += "'" + rest[rest.index(after: rest.startIndex)..<close].replacingOccurrences(of: "'", with: "''") + "'"
                rest = rest[rest.index(after: close)...]
            } else if let (m, i) = tokens.first(where: { rest.hasPrefix($0.0) }) {
                if m == "A" { upperAmPm = true }
                icu += i
                rest = rest.dropFirst(m.count)
            } else {
                let c = rest.removeFirst()
                icu += c.isLetter ? "'\(c)'" : (c == "'" ? "''" : String(c))
            }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = icu
        f.amSymbol = upperAmPm ? "AM" : "am"
        f.pmSymbol = upperAmPm ? "PM" : "pm"
        return f.string(from: date)
    }
}
