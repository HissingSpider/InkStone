import Foundation

/// A value Inkstone knows how to write into YAML frontmatter.
///
/// Deliberately small: frontmatter is metadata Obsidian and Dataview read, not
/// a general serialisation format, and a closed set keeps the emitter provably
/// correct without pulling in a YAML library.
public enum FrontmatterValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case list([String])
    case intList([Int])
}

public enum Frontmatter {

    /// Key order in the emitted block. Anything unlisted follows, sorted, so a
    /// new field never silently reorders an existing note and makes a spurious
    /// diff in the user's vault history.
    static let keyOrder = ["category", "notebook", "needs_review", "updated", "tags"]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// `yyyy-MM-dd`, for the provenance footer.
    public static func dayString(_ date: Date) -> String { dateFormatter.string(from: date) }

    public static func render(_ values: [String: FrontmatterValue]) -> String {
        let ordered = keyOrder.filter { values[$0] != nil }
            + values.keys.filter { !keyOrder.contains($0) }.sorted()

        var lines = ["---"]
        for key in ordered {
            guard let value = values[key] else { continue }
            lines.append("\(key): \(scalar(value))")
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    static func scalar(_ value: FrontmatterValue) -> String {
        switch value {
        case .string(let s): return quote(s)
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .date(let d): return dateFormatter.string(from: d)
        case .list(let items): return "[" + items.map(quote).joined(separator: ", ") + "]"
        case .intList(let items): return "[" + items.map(String.init).joined(separator: ", ") + "]"
        }
    }

    /// Quotes only when YAML needs it, so `tags: [inkstone, handwritten]` stays
    /// readable instead of becoming a wall of quotation marks.
    static func quote(_ string: String) -> String {
        let needsQuotes = string.isEmpty
            || string.rangeOfCharacter(from: CharacterSet(charactersIn: ":#{}[],&*!|>'\"%@`")) != nil
            || string.first?.isWhitespace == true
            || string.last?.isWhitespace == true
            || ["true", "false", "null", "yes", "no", "~"].contains(string.lowercased())
            || Double(string) != nil
        guard needsQuotes else { return string }
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// Splits an existing note into its frontmatter block and body, if any.
    public static func split(_ contents: String) -> (frontmatter: String?, body: String) {
        guard contents.hasPrefix("---\n") else { return (nil, contents) }
        let afterOpener = contents.index(contents.startIndex, offsetBy: 4)
        guard let closer = contents.range(of: "\n---\n", range: afterOpener..<contents.endIndex)
                ?? contents.range(of: "\n---", range: afterOpener..<contents.endIndex)
        else { return (nil, contents) }
        return (String(contents[afterOpener..<closer.lowerBound]),
                String(contents[closer.upperBound...]))
    }

    /// Reads a single scalar out of a raw frontmatter block. Used to check for
    /// `inkstone_lock: true` without parsing YAML in full.
    public static func value(of key: String, in block: String) -> String? {
        for line in block.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key
            else { continue }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return nil
    }
}
