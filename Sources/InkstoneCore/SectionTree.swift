import Foundation

/// A markdown heading and everything beneath it.
///
/// Splitting notes at page boundaries only ever produced notes as coarse as the
/// pages themselves, which is the wrong grain for finding things later. A page
/// headed "Vector operations" that covers adding *and* scaling is two ideas in
/// one note, and neither is findable by name. Parsing the heading structure
/// instead lets each idea become its own note, with the parent left as an index
/// pointing at them.
public struct MarkdownSection: Sendable {
    /// 1 for `#`, 2 for `##`, and 0 for content preceding any heading.
    public var level: Int
    public var title: String?
    /// Text directly under this heading, before any child heading.
    public var content: String
    public var children: [MarkdownSection]

    public init(level: Int, title: String?, content: String = "",
                children: [MarkdownSection] = []) {
        self.level = level
        self.title = title
        self.content = content
        self.children = children
    }

    /// Every heading in this subtree, this one included.
    public var titledDescendants: [MarkdownSection] {
        (title == nil ? [] : [self]) + children.flatMap(\.titledDescendants)
    }

    /// This section rendered back to markdown, headings and all.
    public func flattened() -> String {
        var parts: [String] = []
        if let title, level > 0 {
            parts.append(String(repeating: "#", count: level) + " " + title)
        }
        if !content.isEmpty { parts.append(content) }
        parts += children.map { $0.flattened() }
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension MarkdownSection {

    /// Dissolves headings that only mean "this is more of the last thing".
    ///
    /// A page continuing a topic from the previous one is often headed
    /// "Continued", which is not a topic. Left alone it becomes a note called
    /// Continued, and — worse — adopts the real sub-headings that follow it, so
    /// they end up filed under the marker instead of under the topic they
    /// belong to. Merging such a section into its previous sibling puts both its
    /// content and its children back where they were always meant to be.
    /// `keepTitle` distinguishes the two reasons a heading gets dissolved. A
    /// continuation marker is scaffolding and is discarded; a phrase wrongly
    /// promoted to a heading is the writer's own words and is kept as prose.
    public func dissolvingContinuations(
        matching patterns: [NSRegularExpression],
        demoting demoted: [NSRegularExpression] = []
    ) -> MarkdownSection {
        var result = self
        result.children = []

        func matches(_ title: String, _ set: [NSRegularExpression]) -> Bool {
            let range = NSRange(title.startIndex..<title.endIndex, in: title)
            return set.contains { $0.firstMatch(in: title, range: range) != nil }
        }

        for child in children {
            var resolved = child.dissolvingContinuations(matching: patterns, demoting: demoted)
            let title = resolved.title ?? ""
            let isContinuation = !title.isEmpty && matches(title, patterns)
            let isDemoted = !title.isEmpty && matches(title, demoted)

            guard isContinuation || isDemoted else {
                result.children.append(resolved)
                continue
            }

            // Put the words back into the prose, unless the model already
            // repeated them there — which is exactly why the heading looked
            // spurious in the first place.
            if isDemoted, !resolved.content.lowercased()
                .hasPrefix(title.lowercased()) {
                resolved.content = resolved.content.isEmpty
                    ? title : title + "\n\n" + resolved.content
            }

            // Content is never dropped: it goes to the previous sibling if there
            // is one, and to this section otherwise.
            if var previous = result.children.popLast() {
                previous.content = [previous.content, resolved.content]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
                previous.children += resolved.children
                result.children.append(previous)
            } else {
                result.content = [result.content, resolved.content]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
                result.children += resolved.children
            }
        }
        return result
    }
}

public enum SectionParser {

    /// Parses `markdown` into a tree of headings.
    ///
    /// Fenced code is skipped, because `#` at the start of a line inside a fence
    /// is a comment in half the languages there are, not a heading.
    public static func parse(_ markdown: String) -> MarkdownSection {
        var root = MarkdownSection(level: 0, title: nil)
        // The chain of open sections, root first.
        var stack: [MarkdownSection] = [root]
        var buffer: [String] = []
        var inFence = false

        func flushBuffer() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll()
            guard !text.isEmpty else { return }
            stack[stack.count - 1].content = stack[stack.count - 1].content.isEmpty
                ? text : stack[stack.count - 1].content + "\n\n" + text
        }

        /// Collapses the stack down to `level`, attaching finished sections to
        /// their parents as it goes.
        func close(to level: Int) {
            while stack.count > 1, stack[stack.count - 1].level >= level {
                let finished = stack.removeLast()
                stack[stack.count - 1].children.append(finished)
            }
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                buffer.append(text)
                continue
            }
            guard !inFence, let heading = Self.heading(in: text) else {
                buffer.append(text)
                continue
            }
            flushBuffer()
            close(to: heading.level)
            stack.append(MarkdownSection(level: heading.level, title: heading.title))
        }

        flushBuffer()
        close(to: 1)
        root = stack[0]
        return root
    }

    static func heading(in line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first?.isWhitespace == true else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (hashes, title)
    }
}
