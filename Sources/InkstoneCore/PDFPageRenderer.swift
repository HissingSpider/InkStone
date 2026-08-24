import CoreGraphics
import Foundation
import PDFKit

/// A rasterised PDF page plus the geometry needed to map Vision's normalised
/// coordinates back onto the bitmap.
public struct RenderedPage: Sendable {
    public let index: Int
    public let image: CGImage
    /// Page size in PDF points (72 per inch), post-rotation.
    public let pointSize: CGSize
    /// Pixels per point actually used for `image`.
    public let scale: Double

    public var pixelWidth: Int { image.width }
    public var pixelHeight: Int { image.height }
}

/// Rasterises PDF pages and fingerprints them for change detection.
///
/// Fingerprinting is deliberately decoupled from full-resolution rendering:
/// a run over an untouched 200-page notebook only pays for 200 cheap 96-pixel
/// thumbnails, and the expensive 300 DPI render happens for changed pages only.
public final class PDFPageRenderer {

    public let url: URL
    private let document: PDFDocument

    /// Width in pixels of the thumbnail used for fingerprints. Small enough to
    /// be cheap, large enough that a single added word changes the hash.
    private static let fingerprintWidth = 96

    public init(url: URL) throws {
        guard let document = PDFDocument(url: url) else {
            throw InkstoneError.pdf("cannot open \(url.lastPathComponent)")
        }
        guard !document.isLocked else {
            throw InkstoneError.pdf("\(url.lastPathComponent) is password protected")
        }
        self.url = url
        self.document = document
    }

    public var pageCount: Int { document.pageCount }

    /// Title from PDF metadata, falling back to the file name. GoodNotes writes
    /// the notebook name here, which is what we route on.
    public var documentTitle: String {
        let attributes = document.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String,
           !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// A stable hash of page `index`'s visual content.
    ///
    /// Rendered greyscale at a fixed pixel width, so the value depends on what
    /// is drawn rather than on the DPI the caller happens to be using — the
    /// fingerprint survives a change to `renderDPI` in config.
    public func fingerprint(pageIndex: Int) throws -> String {
        guard let page = document.page(at: pageIndex) else {
            throw InkstoneError.pdf("page \(pageIndex) out of range")
        }
        let bounds = page.bounds(for: .mediaBox)
        let scale = Double(Self.fingerprintWidth) / max(bounds.width, 1)
        let image = try rasterize(page: page, scale: scale, grayscale: true)
        return Hashing.sha256(try Self.rawBytes(of: image))
    }

    /// Renders page `index` at `dpi` for OCR and diagram cropping.
    public func render(pageIndex: Int, dpi: Double) throws -> RenderedPage {
        guard let page = document.page(at: pageIndex) else {
            throw InkstoneError.pdf("page \(pageIndex) out of range")
        }
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let image = try rasterize(page: page, scale: scale, grayscale: false)
        let rotated = page.rotation % 180 != 0
        let pointSize = rotated
            ? CGSize(width: bounds.height, height: bounds.width)
            : CGSize(width: bounds.width, height: bounds.height)
        return RenderedPage(index: pageIndex, image: image, pointSize: pointSize, scale: scale)
    }

    // MARK: Rasterisation

    private func rasterize(page: PDFPage, scale: Double, grayscale: Bool) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        // `page.draw(with:to:)` applies rotation itself, so the destination
        // context must already be sized in the rotated orientation.
        let rotated = page.rotation % 180 != 0
        let logicalWidth = rotated ? bounds.height : bounds.width
        let logicalHeight = rotated ? bounds.width : bounds.height

        let width = max(1, Int((logicalWidth * scale).rounded()))
        let height = max(1, Int((logicalHeight * scale).rounded()))

        let colorSpace = grayscale
            ? CGColorSpaceCreateDeviceGray()
            : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = grayscale
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo)
        else {
            throw InkstoneError.pdf("cannot allocate \(width)x\(height) bitmap for page \(page.label ?? "?")")
        }

        // Handwriting is dark ink on white paper; PDF pages have no background
        // of their own, so paint one or OCR sees ink on transparent black.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        guard let image = context.makeImage() else {
            throw InkstoneError.pdf("rasterisation produced no image")
        }
        return image
    }

    /// Pixel bytes of `image`, normalised into a tightly packed 8-bit grey
    /// buffer so the hash does not depend on row padding chosen by CoreGraphics.
    static func rawBytes(of image: CGImage) throws -> Data {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height)
        let result: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard result else { throw InkstoneError.pdf("cannot normalise page bitmap") }
        return Data(buffer)
    }
}
