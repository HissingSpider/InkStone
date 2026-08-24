import CoreGraphics
import CoreText
import Foundation
@testable import InkstoneCore

/// Builds PDFs on the fly so the tests exercise the real PDFKit → Vision path
/// rather than a mock of it. Printed text is not handwriting, but every stage
/// below the recogniser — rendering, hashing, line grouping, markdown, diagram
/// subtraction, writing — behaves identically, and it makes the end-to-end test
/// run anywhere without checked-in binary fixtures.
enum Fixtures {

    struct PageSpec {
        var lines: [String] = []
        /// Draw a boxed sketch in the lower half of the page.
        var includeDiagram = false
    }

    static let pageSize = CGSize(width: 612, height: 792)

    @discardableResult
    static func makePDF(at url: URL, title: String, pages: [PageSpec]) throws -> URL {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title]

        guard let context = CGContext(
            url as CFURL, mediaBox: &mediaBox, info as CFDictionary)
        else { throw InkstoneError.io("cannot create PDF context") }

        for page in pages {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(mediaBox)
            draw(page, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private static func draw(_ page: PageSpec, in context: CGContext) {
        var y = pageSize.height - 90
        for line in page.lines {
            // Large type: Vision needs a decent glyph height to read reliably,
            // and the markdown heuristics key off relative line height anyway.
            let size: CGFloat = line.hasPrefix("#") ? 34 : 24
            let text = line.hasPrefix("#")
                ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
            drawText(text, at: CGPoint(x: 72, y: y), size: size, in: context)
            y -= size * 1.9
        }

        guard page.includeDiagram else { return }
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(3)
        context.stroke(CGRect(x: 150, y: 150, width: 200, height: 130))
        context.stroke(CGRect(x: 200, y: 190, width: 100, height: 50))
        context.move(to: CGPoint(x: 150, y: 150))
        context.addLine(to: CGPoint(x: 350, y: 280))
        context.strokePath()
    }

    private static func drawText(
        _ text: String, at point: CGPoint, size: CGFloat, in context: CGContext
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: CGColor(gray: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    /// A scratch directory removed when `body` returns.
    static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inkstone-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    static func line(_ text: String, y: Double, height: Double = 0.02,
                     x: Double = 0.1, width: Double = 0.4,
                     confidence: Double = 0.9) -> TextLine {
        TextLine(blocks: [TextBlock(
            text: text, confidence: confidence,
            // Vision space: origin bottom-left, so a top-down y becomes 1 - y.
            boundingBox: CGRect(x: x, y: 1 - y - height, width: width, height: height))])
    }
}
