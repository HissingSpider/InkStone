import CoreGraphics
import Foundation
import Vision

/// Local, on-device handwriting recognition via the Vision framework.
///
/// Runs `.accurate` — the slow path — because handwriting is exactly the case
/// where `.fast` falls apart, and the pipeline is batch, not interactive.
public struct VisionOCR: Sendable {

    public var languages: [String]
    public var usesLanguageCorrection: Bool
    public var customWords: [String]

    /// Blocks shorter than this fraction of page height are treated as ink
    /// noise rather than text — a stray tick that Vision reads as "l" or "-".
    private static let minBlockHeight = 0.004

    public init(config: InkstoneConfig) {
        self.languages = config.recognitionLanguages
        self.usesLanguageCorrection = config.usesLanguageCorrection
        self.customWords = config.customWords
    }

    public init(languages: [String] = ["en-US"], usesLanguageCorrection: Bool = true,
                customWords: [String] = []) {
        self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.customWords = customWords
    }

    /// Recognises text in `page` and returns it grouped into reading-order lines.
    public func transcribe(_ page: RenderedPage) throws -> PageTranscript {
        let blocks = try recognize(page.image)
        return PageTranscript(
            pageIndex: page.index,
            lines: Self.groupIntoLines(blocks),
            source: .vision)
    }

    /// Raw recognition, one `TextBlock` per Vision observation.
    public func recognize(_ image: CGImage) throws -> [TextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        request.recognitionLanguages = languages
        if !customWords.isEmpty { request.customWords = customWords }
        // Vision's default minimum is tuned for signage; handwriting on a
        // 300 DPI page is proportionally much smaller.
        request.minimumTextHeight = Float(Self.minBlockHeight)

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw InkstoneError.ocr("Vision request failed: \(error.localizedDescription)")
        }

        guard let observations = request.results else { return [] }
        return observations.compactMap { observation -> TextBlock? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard observation.boundingBox.height >= Self.minBlockHeight else { return nil }
            return TextBlock(
                text: text,
                confidence: Double(candidate.confidence),
                boundingBox: observation.boundingBox)
        }
    }

    // MARK: Reading order

    /// Groups blocks into lines and orders them top-to-bottom, left-to-right.
    ///
    /// Vision returns observations in an order that is stable but not reading
    /// order for handwriting, and it splits a single handwritten line into
    /// several observations whenever the pen lifts for long enough. Two blocks
    /// join the same line when their vertical spans overlap by more than half
    /// the shorter block's height — proportional rather than absolute, so it
    /// works for a title and a footnote on the same page.
    public static func groupIntoLines(_ blocks: [TextBlock]) -> [TextLine] {
        guard !blocks.isEmpty else { return [] }

        let sorted = blocks.sorted { $0.topDownMidY < $1.topDownMidY }
        var lines: [[TextBlock]] = []

        for block in sorted {
            if let index = lines.indices.last, sharesLine(block, with: lines[index]) {
                lines[index].append(block)
            } else {
                lines.append([block])
            }
        }

        return lines.map { line in
            TextLine(blocks: line.sorted { $0.boundingBox.minX < $1.boundingBox.minX })
        }
    }

    private static func sharesLine(_ block: TextBlock, with line: [TextBlock]) -> Bool {
        guard let reference = line.max(by: { $0.height < $1.height }) else { return false }
        let a = block.boundingBox, b = reference.boundingBox
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard overlap > 0 else { return false }
        return overlap > 0.5 * min(a.height, b.height)
    }
}
