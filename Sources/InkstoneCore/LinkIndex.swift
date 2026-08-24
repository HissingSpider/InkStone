import Foundation

/// Turns bare mentions of a topic into Obsidian wikilinks.
///
/// A vault earns its keep through its links, and a transcription that says
/// "vectors" in prose while a `Vectors` note sits next to it has thrown away the
/// connection. This builds an index of every note title in the vault — the
/// user's own notes as well as the ones being written now — and links the first
/// mention of each.
///
/// The restraint matters as much as the linking. Linking every occurrence of
/// every word turns a note into a sea of blue, so this links the first mention
/// only, never inside an existing link, never inside code or maths, and never a
/// note to itself.
public struct LinkIndex: Sendable {

    /// Lowercased title → the note name to link to.
    private var entries: [String: String] = [:]

    /// Titles shorter than this are ignored. Below four characters, matches are
    /// overwhelmingly incidental — a note called "Set" would link the word "set"
    /// in every sentence that used it as a verb.
    public var minimumTitleLength = 4

    public init(titles: [String] = []) {
        for title in titles { add(title) }
    }

    public mutating func add(_ title: String) {
        let key = title.lowercased()
        guard title.count >= minimumTitleLength else { return }
        // First writer wins, so a note being written now does not displace a
        // note the user already had.
        if entries[key] == nil { entries[key] = title }
    }

    public var titles: [String] { Array(entries.values) }
    public var isEmpty: Bool { entries.isEmpty }

    /// Every markdown note already in the vault, by file name.
    public static func scanningVault(at url: URL, limit: Int = 5_000) -> LinkIndex {
        var index = LinkIndex()
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return index }

        var seen = 0
        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "md" else { continue }
            index.add(file.deletingPathExtension().lastPathComponent)
            seen += 1
            if seen >= limit { break }
        }
        return index
    }

    /// Links the first mention of each known title in `markdown`.
    public func linkify(_ markdown: String, excluding selfTitle: String) -> String {
        guard !entries.isEmpty else { return markdown }

        // Longest first, so "Vector operations" wins over "Vector" and the
        // shorter title does not carve up the longer one's phrase.
        let candidates = entries.values
            .filter { $0.lowercased() != selfTitle.lowercased() }
            .sorted { $0.count > $1.count }

        var result = markdown
        for title in candidates {
            result = Self.linkFirstMention(of: title, in: result)
        }
        return result
    }

    /// Replaces the first standalone mention of `title`, skipping regions where
    /// a link would be wrong or invisible.
    static func linkFirstMention(of title: String, in markdown: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: title)
        // \b would not fire for titles ending in punctuation, so bound on
        // characters that cannot be part of a word instead.
        let pattern = #"(?<![\w\[|#!])"# + escaped + #"(?![\w\]|])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return markdown }

        let protectedRanges = Self.protectedRanges(in: markdown)
        let full = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)

        for match in regex.matches(in: markdown, range: full) {
            guard !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            else { continue }
            guard let range = Range(match.range, in: markdown) else { continue }

            let matched = String(markdown[range])
            // Preserve what the writer wrote. If the casing differs from the
            // note's name, use an aliased link rather than silently rewriting
            // their sentence.
            let replacement = matched == title ? "[[\(title)]]" : "[[\(title)|\(matched)]]"
            return markdown.replacingCharacters(in: range, with: replacement)
        }
        return markdown
    }

    /// Regions a link must not be inserted into: existing links and embeds,
    /// fenced and inline code, LaTeX, and headings.
    ///
    /// Headings are excluded because a linked heading reads as a navigation
    /// element rather than a title, and because the section heading is usually
    /// the note's own name.
    static func protectedRanges(in markdown: String) -> [NSRange] {
        let patterns = [
            #"!?\[\[[^\]]*\]\]"#,          // wikilinks and embeds
            #"\[[^\]]*\]\([^)]*\)"#,       // markdown links
            #"```[\s\S]*?```"#,            // fenced code
            #"`[^`\n]*`"#,                 // inline code
            #"\$\$[\s\S]*?\$\$"#,          // display maths
            #"\$[^$\n]*\$"#,               // inline maths
            #"(?m)^#{1,6} .*$"#,           // headings
            #"(?m)^>.*$"#,                 // callouts and quotes
        ]
        let full = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return patterns.flatMap { pattern -> [NSRange] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: markdown, range: full).map(\.range)
        }
    }
}
