import CoreGraphics
import Foundation

/// Turns OCR lines into Obsidian-flavoured markdown.
///
/// The guiding principle is fidelity over prettiness: handwritten notes carry
/// meaning in their layout, so a line on the page stays a line in the note.
/// Only structure that is unambiguous from geometry — headings, bullets,
/// indentation, paragraph breaks — is promoted to markdown syntax.
/// One rendered markdown line, tagged with its vertical position on the page.
public struct MarkdownElement: Sendable, Equatable {
    /// 0 at the top of the page, 1 at the bottom.
    public var topDownY: Double
    public var text: String
    /// True for the blank line inserted at a paragraph break.
    public var isBreak: Bool

    public init(topDownY: Double, text: String, isBreak: Bool = false) {
        self.topDownY = topDownY
        self.text = text
        self.isBreak = isBreak
    }
}

public struct MarkdownBuilder: Sendable {

    /// A line taller than `medianHeight * headingRatio` reads as a heading.
    public var headingRatio: Double = 1.35

    /// A gap larger than `medianPitch * paragraphGapRatio` starts a new block.
    public var paragraphGapRatio: Double = 1.7

    /// One indent level per this fraction of page width of left-margin offset.
    /// About half an inch on Letter — the distance a hand actually moves when
    /// starting a sub-point, rather than the tighter unit typeset text uses.
    public var indentUnit: Double = 0.06

    public init() {}

    private static let bulletMarkers: Set<Character> = ["•", "·", "‣", "▪", "◦", "-", "–", "—", "*", "»", "○"]

    public func markdown(for transcript: PageTranscript) -> String {
        if let vlm = transcript.vlmMarkdown {
            return vlm.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return markdown(for: transcript.lines)
    }

    public func markdown(for lines: [TextLine]) -> String {
        Self.join(elements(for: lines))
    }

    /// Markdown for `lines`, each element tagged with where it sat on the page.
    ///
    /// Positions are what let diagram embeds land in the right place later, so
    /// this — not the joined string — is the primary output.
    public func elements(for lines: [TextLine]) -> [MarkdownElement] {
        guard !lines.isEmpty else { return [] }

        let heights = lines.map(\.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let pitch = medianPitch(of: lines) ?? medianHeight * 1.6
        let leftMargin = lines.map { $0.boundingBox.minX }.min() ?? 0

        var output: [MarkdownElement] = []
        var previousBottom: Double?

        for line in lines {
            let text = line.text
            guard !text.isEmpty else { continue }

            if let previousBottom, line.topDownMinY - previousBottom > pitch * paragraphGapRatio {
                output.append(MarkdownElement(topDownY: line.topDownMinY, text: "", isBreak: true))
            }
            previousBottom = line.topDownMinY + line.height

            let indent = Int(((line.boundingBox.minX - leftMargin) / indentUnit).rounded(.down))
            output.append(MarkdownElement(
                topDownY: line.topDownMinY,
                text: render(line: line, text: text,
                             medianHeight: medianHeight,
                             indentLevel: max(0, min(indent, 4))),
                isBreak: false))
        }
        return output
    }

    /// Joins elements into a markdown string, collapsing runs of blank lines.
    public static func join(_ elements: [MarkdownElement]) -> String {
        collapseBlankRuns(elements.map(\.text)).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Line rendering

    private func render(line: TextLine, text: String, medianHeight: Double, indentLevel: Int) -> String {
        let pad = String(repeating: "  ", count: indentLevel)

        if let (marker, body) = Self.splitOrderedMarker(text) {
            return "\(pad)\(marker) \(body)"
        }
        if let body = Self.splitBulletMarker(text) {
            return "\(pad)- \(body)"
        }
        if let body = Self.splitTaskMarker(text) {
            return "\(pad)- [ ] \(body)"
        }
        // A tall line that is not a list item is a heading. Indentation still
        // applies to sub-headings written smaller and further in.
        if line.height > medianHeight * headingRatio {
            let level = line.height > medianHeight * (headingRatio + 0.5) ? "##" : "###"
            return "\(level) \(text)"
        }
        return "\(pad)\(text)"
    }

    /// `"1. foo"`, `"2) foo"`, `"iii. foo"` → an ordered-list marker.
    static func splitOrderedMarker(_ text: String) -> (String, String)? {
        let pattern = #"^\s*(\d{1,2})[\.\)]\s+(.*)$"#
        guard let match = text.firstMatch(pattern), match.count == 3 else { return nil }
        return ("\(match[1]).", match[2])
    }

    static func splitBulletMarker(_ text: String) -> String? {
        guard let first = text.first, bulletMarkers.contains(first) else { return nil }
        let body = text.dropFirst().trimmingCharacters(in: .whitespaces)
        // "-" alone, or "- " followed by nothing, is a rule or a stray stroke.
        guard !body.isEmpty else { return nil }
        // An em dash mid-sentence is not a bullet; require whitespace after it.
        guard text.dropFirst().first?.isWhitespace == true else { return nil }
        return body
    }

    /// `"[] foo"`, `"[ ] foo"`, `"☐ foo"` → an unchecked task.
    static func splitTaskMarker(_ text: String) -> String? {
        let pattern = #"^\s*(?:\[\s*\]|☐|□)\s*(.+)$"#
        guard let match = text.firstMatch(pattern), match.count == 2 else { return nil }
        return match[1]
    }

    // MARK: Geometry

    /// Median distance between the tops of consecutive lines — the page's
    /// natural line pitch, which is what a paragraph gap must beat.
    private func medianPitch(of lines: [TextLine]) -> Double? {
        guard lines.count > 2 else { return nil }
        let gaps = zip(lines, lines.dropFirst())
            .map { $1.topDownMinY - $0.topDownMinY }
            .filter { $0 > 0 }
            .sorted()
        guard !gaps.isEmpty else { return nil }
        return gaps[gaps.count / 2]
    }

    /// Squeezes runs of blank lines to one and drops blanks at either end.
    static func collapseBlankRuns(_ lines: [String]) -> [String] {
        var output: [String] = []
        for line in lines {
            if line.isEmpty, output.last?.isEmpty ?? true { continue }
            output.append(line)
        }
        while output.last?.isEmpty == true { output.removeLast() }
        return output
    }
}

extension String {
    /// Returns the full match plus capture groups, or nil when `pattern` misses.
    func firstMatch(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: self) else { return "" }
            return String(self[range])
        }
    }
}
