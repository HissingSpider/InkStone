import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageEncoding {

    /// Longest edge, in pixels, sent to the VLM.
    ///
    /// Anthropic downsamples anything larger anyway, and a 300 DPI page is far
    /// above it — sending the full render would just burn upload bandwidth for
    /// no gain in recognition.
    public static let maxVLMEdge = 1_568

    /// JPEG rather than PNG for upload: a scanned page compresses roughly ten
    /// to one at quality 0.8 with no visible effect on handwriting legibility.
    public static func jpegData(_ image: CGImage, quality: Double = 0.8) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw InkstoneError.io("cannot create JPEG encoder") }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw InkstoneError.io("JPEG encoding failed")
        }
        return data as Data
    }

    /// Scales `image` down so its longest edge is at most `maxEdge`. Images
    /// already within budget are returned untouched.
    public static func downscale(_ image: CGImage, maxEdge: Int = maxVLMEdge) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxEdge else { return image }

        let scale = Double(maxEdge) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw InkstoneError.io("cannot allocate downscale buffer") }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else {
            throw InkstoneError.io("downscale produced no image")
        }
        return result
    }

    /// Base64 JPEG at VLM-appropriate resolution.
    public static func vlmPayload(_ image: CGImage) throws -> String {
        try jpegData(downscale(image)).base64EncodedString()
    }
}
