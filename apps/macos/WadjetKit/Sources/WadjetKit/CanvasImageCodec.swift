import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image formats shared by Canvas packages and flattened Screenshot exports.
public enum CanvasImageCodec {
    /// Encodes HDR with an ISO gain map, or SDR HEIC when no extended pixels exist.
    public static func heic(_ image: CGImage, quality: Double = 1) throws -> Data {
        let headroom = max(image.contentHeadroom, image.calculatedContentHeadroom)
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        var source = image
        if headroom > 1 {
            options[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
            // ImageIO clips extended pixels when their headroom is unknown, even with a gain-map request.
            if image.contentHeadroom == 0 {
                guard let tagged = CGImageCreateCopyWithContentHeadroom(headroom, image) else {
                    throw CanvasDocumentError.imageEncodingFailed
                }
                source = tagged
            }
        }
        return try encode(source, type: .heic, options: options)
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                kCGImageSourceShouldAllowFloat: true,
              ] as CFDictionary) else { throw CanvasDocumentError.imageDecodingFailed }
        return image
    }

    /// Encodes an SDR PNG suitable for normal image consumers.
    public static func png(_ image: CGImage) throws -> Data {
        // Package thumbnails and normal PNG exports are SDR; HEIC carries HDR.
        try encode(sdr(image), type: .png, options: [:])
    }

    static func sdr(_ image: CGImage) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CanvasDocumentError.renderFailed
        }
        context.setEDRTargetHeadroom(1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let sdr = context.makeImage() else { throw CanvasDocumentError.renderFailed }
        return sdr
    }

    private static func encode(_ image: CGImage, type: UTType, options: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CanvasDocumentError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CanvasDocumentError.imageEncodingFailed }
        return data as Data
    }
}
