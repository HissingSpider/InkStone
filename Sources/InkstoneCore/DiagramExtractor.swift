import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The result of one page's diagram pass.
public struct DiagramScan: Sendable {
    public var crops: [DiagramCrop]
    /// Share of the page's pixels that carry ink, before text is subtracted.
    /// Feeds the confidence gate's "dense ink, little text" signal.
    public var inkCoverage: Double
}

/// A region of a page that holds drawing rather than writing.
public struct DiagramCrop: Sendable, Equatable, Codable {
    public var pageIndex: Int
    /// Order on the page, top-to-bottom then left-to-right.
    public var index: Int
    /// Region in the rendered page's pixel coordinates (origin top-left).
    public var pixelRect: CGRect
    /// Vertical position of the crop's top edge, 0 at the top of the page.
    /// Used to slot the embed into the right place in the transcribed text.
    public var anchorTopDownY: Double
    /// File name written into the vault's attachments folder.
    public var fileName: String

    public var wikilink: String { "![[\(fileName)]]" }
}

/// Finds diagrams by subtracting recognised text from the page's ink.
///
/// The insight is that Vision already tells us where every word is. Whatever ink
/// remains after erasing those boxes is, by elimination, drawing: arrows, boxes,
/// graphs, circuit symbols, marginal sketches. That is far more reliable for
/// handwriting than trying to classify strokes directly, because it inherits
/// Vision's own judgement about what counts as text.
public struct DiagramExtractor: Sendable {

    /// Grey level at or below which a pixel counts as ink.
    public var inkThreshold: UInt8 = 190

    /// Side of a mask cell in pixels at 300 DPI; scaled with the actual DPI.
    /// Working on cells rather than pixels keeps connected-component labelling
    /// on a ~200k-element grid instead of an 8M-pixel one.
    public var cellSizeAt300DPI: Int = 6

    /// Text boxes are grown by this fraction of their height before erasing,
    /// so ascenders, descenders and Vision's slightly tight boxes come out too.
    public var textBoxPadding: Double = 0.35

    /// Components whose boxes come within this many cells of each other merge.
    /// A diagram is rarely one connected stroke.
    public var mergeGapCells: Int = 6

    /// Minimum share of the page a crop must cover to be kept.
    public var minAreaFraction: Double = 0.01

    /// Ceiling on connected components before the diagram pass gives up.
    ///
    /// Merging is quadratic in the component count, and a speckled or heavily
    /// shaded scan can produce tens of thousands of them. Skipping diagram
    /// extraction on such a page costs the user some embeds; hanging the nightly
    /// run costs them the whole thing.
    public var maxComponents = 4_000

    /// Minimum share of a candidate's box that must actually be inked. Rejects
    /// a large empty box formed by two far-apart specks.
    public var minInkDensity: Double = 0.015

    /// Pixels of breathing room added around a crop.
    public var cropPadding: Int = 12

    public init() {}

    public init(config: InkstoneConfig) {
        self.minAreaFraction = config.minDiagramAreaFraction
        self.cropPadding = config.diagramCropPadding
    }

    /// Locates diagrams on `page`, writes each as a PNG under `attachmentsURL`,
    /// and returns them in reading order.
    ///
    /// `slug` names the files: `<slug>-p<page>-<n>.png`.
    public func extract(
        from page: RenderedPage, textBlocks: [TextBlock],
        slug: String, attachmentsURL: URL
    ) throws -> DiagramScan {
        let scan = try locate(in: page, textBlocks: textBlocks)
        let candidates = scan.rects
        guard !candidates.isEmpty else {
            return DiagramScan(crops: [], inkCoverage: scan.inkCoverage)
        }

        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        var crops: [DiagramCrop] = []
        for (offset, rect) in candidates.enumerated() {
            let padded = rect
                .insetBy(dx: -CGFloat(cropPadding), dy: -CGFloat(cropPadding))
                .intersection(CGRect(x: 0, y: 0, width: page.pixelWidth, height: page.pixelHeight))
            guard let cropped = page.image.cropping(to: padded) else { continue }

            let name = "\(slug)-p\(page.index + 1)-\(offset + 1).png"
            try Self.writePNG(cropped, to: attachmentsURL.appendingPathComponent(name))

            crops.append(DiagramCrop(
                pageIndex: page.index,
                index: offset,
                pixelRect: padded,
                anchorTopDownY: Double(padded.minY) / Double(page.pixelHeight),
                fileName: name))
        }
        return DiagramScan(crops: crops, inkCoverage: scan.inkCoverage)
    }

    // MARK: Detection

    public struct Located: Sendable {
        public var rects: [CGRect]
        public var inkCoverage: Double
    }

    /// Returns candidate diagram rectangles in pixel space, reading order.
    public func locate(in page: RenderedPage, textBlocks: [TextBlock]) throws -> Located {
        let width = page.pixelWidth, height = page.pixelHeight
        let bytes = try PDFPageRenderer.rawBytes(of: page.image)

        let cellSize = max(2, Int((Double(cellSizeAt300DPI) * page.scale / (300.0 / 72.0)).rounded()))
        let columns = (width + cellSize - 1) / cellSize
        let rows = (height + cellSize - 1) / cellSize

        var inkCounts = [Int32](repeating: 0, count: columns * rows)
        bytes.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let rowOffset = y * width
                let cellRow = (y / cellSize) * columns
                for x in 0..<width where pixels[rowOffset + x] <= inkThreshold {
                    inkCounts[cellRow + x / cellSize] += 1
                }
            }
        }

        let inkedPixels = inkCounts.reduce(0) { $0 + Int($1) }
        let inkCoverage = Double(inkedPixels) / Double(max(1, width * height))

        // Erase everything Vision claimed as text.
        eraseText(textBlocks, from: &inkCounts,
                  columns: columns, rows: rows, cellSize: cellSize,
                  pixelWidth: width, pixelHeight: height)

        // A cell survives only with real ink in it, not a single stray pixel.
        let minCellInk = Int32(max(2, (cellSize * cellSize) / 40))
        var mask = inkCounts.map { $0 >= minCellInk }

        var boxes = Self.connectedComponents(mask: &mask, columns: columns, rows: rows)
        guard boxes.count <= maxComponents else {
            log.warn("page \(page.index + 1): \(boxes.count) ink components — "
                     + "too speckled to separate diagrams, skipping extraction")
            return Located(rects: [], inkCoverage: inkCoverage)
        }
        boxes = Self.mergeNearby(boxes, gap: mergeGapCells)

        let pageArea = Double(columns * rows)
        let candidates = boxes.filter { box in
            let area = Double(box.rect.width * box.rect.height)
            guard area / pageArea >= minAreaFraction else { return false }
            guard Double(box.cellCount) / area >= minInkDensity else { return false }
            // Reject page rules and long underlines: wide, but only a cell or
            // two tall, so nothing is really drawn there.
            let isHairline = box.rect.height <= 2 && box.rect.width > columns / 5
            return !isHairline
        }

        let rects = candidates
            .sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
            .map { box in
                CGRect(x: box.rect.minX * cellSize,
                       y: box.rect.minY * cellSize,
                       width: box.rect.width * cellSize,
                       height: box.rect.height * cellSize)
                    .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            }
        return Located(rects: rects, inkCoverage: inkCoverage)
    }

    private func eraseText(
        _ blocks: [TextBlock], from cells: inout [Int32],
        columns: Int, rows: Int, cellSize: Int, pixelWidth: Int, pixelHeight: Int
    ) {
        for block in blocks {
            // Vision's box is normalised with a bottom-left origin; the bitmap
            // is top-left. Flip y while converting to pixels.
            let padY = block.boundingBox.height * textBoxPadding
            let padX = block.boundingBox.height * textBoxPadding
            let minX = (block.boundingBox.minX - padX) * Double(pixelWidth)
            let maxX = (block.boundingBox.maxX + padX) * Double(pixelWidth)
            let minY = (1 - block.boundingBox.maxY - padY) * Double(pixelHeight)
            let maxY = (1 - block.boundingBox.minY + padY) * Double(pixelHeight)

            let columnRange = max(0, Int(minX) / cellSize)...min(columns - 1, max(0, Int(maxX) / cellSize))
            let rowRange = max(0, Int(minY) / cellSize)...min(rows - 1, max(0, Int(maxY) / cellSize))
            guard columnRange.lowerBound <= columnRange.upperBound,
                  rowRange.lowerBound <= rowRange.upperBound else { continue }

            for row in rowRange {
                for column in columnRange { cells[row * columns + column] = 0 }
            }
        }
    }

    // MARK: Connected components

    struct CellBox: Sendable {
        var rect: CellRect
        var cellCount: Int
    }

    /// Integer rectangle in cell space.
    struct CellRect: Sendable {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }

        func expanded(by gap: Int) -> CellRect {
            CellRect(minX: minX - gap, minY: minY - gap, maxX: maxX + gap, maxY: maxY + gap)
        }

        func intersects(_ other: CellRect) -> Bool {
            minX <= other.maxX && other.minX <= maxX && minY <= other.maxY && other.minY <= maxY
        }

        mutating func formUnion(_ other: CellRect) {
            minX = Swift.min(minX, other.minX); minY = Swift.min(minY, other.minY)
            maxX = Swift.max(maxX, other.maxX); maxY = Swift.max(maxY, other.maxY)
        }
    }

    /// 8-connected labelling by iterative flood fill. Iterative rather than
    /// recursive: a full-page sketch is one component with tens of thousands of
    /// cells, which would blow the stack.
    static func connectedComponents(mask: inout [Bool], columns: Int, rows: Int) -> [CellBox] {
        var boxes: [CellBox] = []
        var stack: [Int] = []

        for start in 0..<(columns * rows) where mask[start] {
            mask[start] = false
            stack.append(start)

            var rect = CellRect(minX: start % columns, minY: start / columns,
                                maxX: start % columns, maxY: start / columns)
            var count = 0

            while let index = stack.popLast() {
                count += 1
                let x = index % columns, y = index / columns
                rect.formUnion(CellRect(minX: x, minY: y, maxX: x, maxY: y))

                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < rows else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < columns else { continue }
                        let neighbour = ny * columns + nx
                        if mask[neighbour] {
                            mask[neighbour] = false
                            stack.append(neighbour)
                        }
                    }
                }
            }
            boxes.append(CellBox(rect: rect, cellCount: count))
        }
        return boxes
    }

    /// Repeatedly unions boxes that come within `gap` cells of each other, so a
    /// sketch drawn as separate strokes ends up as one crop.
    static func mergeNearby(_ boxes: [CellBox], gap: Int) -> [CellBox] {
        var current = boxes
        var merged = true
        while merged {
            merged = false
            var result: [CellBox] = []
            for box in current {
                if let index = result.firstIndex(where: {
                    $0.rect.expanded(by: gap).intersects(box.rect.expanded(by: gap))
                }) {
                    result[index].rect.formUnion(box.rect)
                    result[index].cellCount += box.cellCount
                    merged = true
                } else {
                    result.append(box)
                }
            }
            current = result
        }
        return current
    }

    // MARK: Output

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw InkstoneError.io("cannot create PNG at \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw InkstoneError.io("cannot write PNG at \(url.path)")
        }
    }
}

private func < (a: (Int, Int), b: (Int, Int)) -> Bool {
    a.0 != b.0 ? a.0 < b.0 : a.1 < b.1
}
