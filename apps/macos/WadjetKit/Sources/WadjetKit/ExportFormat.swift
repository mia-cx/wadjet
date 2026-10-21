import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension CanvasImageCodec {
    /// the formats the Editor's Export offers, in its popup's order
    public static let exportTypes: [UTType] = [.png, .jpeg, .heic]

    /// Export's starting format: the opened image's own when Export offers it,
    /// else HEIC for an HDR Canvas and PNG otherwise
    public static func exportType(source: URL?, hdr: Bool) -> UTType {
        source.flatMap { UTType(filenameExtension: $0.pathExtension) }
            .flatMap { t in exportTypes.first { t.conforms(to: $0) } }
            ?? (hdr ? .heic : .png)
    }

    /// encodes `image` as one of `exportTypes`
    public static func export(_ image: CGImage, as type: UTType) throws -> Data {
        switch type {
        case .heic: try heic(image)
        case .jpeg: try jpeg(image)
        default: try png(image)
        }
    }

    /// JPEG: SDR in Display P3 like `png`, at `jpegQuality`
    public static func jpeg(_ image: CGImage, quality: Double = jpegQuality) throws -> Data {
        try encode(sdr(image, colourSpace: CGColorSpace.displayP3), type: .jpeg,
                   options: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    public static let jpegQuality = 0.9
}
