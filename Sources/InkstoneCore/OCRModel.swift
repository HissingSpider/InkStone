import CoreGraphics
import Foundation

/// Where a page's text came from. Recorded in frontmatter so a reader can tell
/// a local transcription from one a cloud model cleaned up.
public enum TranscriptSource: String, Codable, Sendable {
    case vision
    case vlm
}

/// One recognised run of text with its position on the page.
///
/// `boundingBox` is in Vision's normalised space: origin bottom-left, values in
/// 0...1 relative to the page. Converting to pixels is `DiagramExtractor`'s job.
public struct TextBlock: Sendable, Equatable {
    public var text: String
    public var confidence: Double
    public var boundingBox: CGRect

    public init(text: String, confidence: Double, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }

    /// Vertical midpoint, top-down (0 at the top of the page). Reading order
    /// is easier to reason about with the y axis flipped.
    public var topDownMidY: Double { 1 - (boundingBox.midY) }
    public var topDownMinY: Double { 1 - boundingBox.maxY }
    public var height: Double { boundingBox.height }
}

/// A line of the page: blocks that share a horizontal band, left to right.
public struct TextLine: Sendable, Equatable {
    public var blocks: [TextBlock]

    public var text: String {
        blocks.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    public var boundingBox: CGRect {
        blocks.dropFirst().reduce(blocks.first?.boundingBox ?? .zero) { $0.union($1.boundingBox) }
    }

    /// Character-weighted mean confidence — a long confident line should not be
    /// dragged down by a two-character stray mark next to it.
    public var confidence: Double {
        let weighted = blocks.reduce(0.0) { $0 + $1.confidence * Double($1.text.count) }
        let characters = blocks.reduce(0) { $0 + $1.text.count }
        return characters > 0 ? weighted / Double(characters) : 0
    }

    public var topDownMinY: Double { blocks.map(\.topDownMinY).min() ?? 0 }
    public var height: Double { boundingBox.height }
}

/// Everything Inkstone knows about one transcribed page.
public struct PageTranscript: Sendable {
    public var pageIndex: Int
    public var lines: [TextLine]
    public var source: TranscriptSource
    /// Populated when the page went through the VLM: the model's markdown,
    /// used verbatim instead of `lines`.
    public var vlmMarkdown: String?
    /// Diagrams cropped out of this page, in reading order.
    public var diagrams: [DiagramCrop] = []

    public init(pageIndex: Int, lines: [TextLine], source: TranscriptSource,
                vlmMarkdown: String? = nil, diagrams: [DiagramCrop] = []) {
        self.pageIndex = pageIndex
        self.lines = lines
        self.source = source
        self.vlmMarkdown = vlmMarkdown
        self.diagrams = diagrams
    }

    public var blocks: [TextBlock] { lines.flatMap(\.blocks) }

    public var characterCount: Int { lines.reduce(0) { $0 + $1.text.count } }

    /// Character-weighted mean confidence across the page.
    ///
    /// A page with no recognised text scores 1.0 rather than 0: a blank page is
    /// a confident "nothing here", not a failed transcription, and escalating
    /// blank pages to a paid model would be pure waste.
    public var confidence: Double {
        guard characterCount > 0 else { return 1.0 }
        let weighted = lines.reduce(0.0) { $0 + $1.confidence * Double($1.text.count) }
        return weighted / Double(characterCount)
    }

    public var isBlank: Bool { characterCount == 0 }
}
