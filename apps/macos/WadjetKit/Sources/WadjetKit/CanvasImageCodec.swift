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
              let lazy = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                kCGImageSourceShouldAllowFloat: true,
                kCGImageSourceShouldCache: false,
              ] as CFDictionary)
        else { throw CanvasDocumentError.imageDecodingFailed }
        return owningPixels(lazy)
    }

    /// Copies an ImageIO image into pixels it owns. A lazily decoded image
    /// reads from an ImageIO cache block on every draw, and under memory
    /// pressure ImageIO can unmap that block while CoreGraphics is still
    /// copying from it (SIGSEGV/SIGBUS in `imageProvider_getBytesAtPosition`).
    /// A Canvas keeps its images while its Editor is open, so it copies once.
    /// Where ImageIO can't hand its pixels over (CI's virtual Macs), the lazy
    /// image is returned unchanged.
    static func owningPixels(_ lazy: CGImage) -> CGImage {
        guard let pixels = lazy.dataProvider?.data,
              let provider = CGDataProvider(data: pixels),
              let space = lazy.colorSpace,
              let owned = CGImage(width: lazy.width, height: lazy.height,
                bitsPerComponent: lazy.bitsPerComponent, bitsPerPixel: lazy.bitsPerPixel,
                bytesPerRow: lazy.bytesPerRow, space: space, bitmapInfo: lazy.bitmapInfo,
                provider: provider, decode: lazy.decode, shouldInterpolate: lazy.shouldInterpolate,
                intent: lazy.renderingIntent) else { return lazy }
        guard lazy.contentHeadroom > 0 else { return owned }
        return CGImageCreateCopyWithContentHeadroom(lazy.contentHeadroom, owned) ?? lazy
    }

    /// Encodes an SDR PNG in Display P3 so wide-gamut Screenshots retain their
    /// colours. Thumbnails can request sRGB; HEIC carries HDR.
    public static func png(_ image: CGImage, colourSpace: CFString = CGColorSpace.displayP3) throws -> Data {
        try encode(sdr(image, colourSpace: colourSpace), type: .png, options: [:])
    }

    static func sdr(_ image: CGImage, colourSpace: CFString = CGColorSpace.sRGB) throws -> CGImage {
        guard let space = CGColorSpace(name: colourSpace),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CanvasDocumentError.renderFailed
        }
        context.setEDRTargetHeadroom(1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let sdr = context.makeImage() else { throw CanvasDocumentError.renderFailed }
        return sdr
    }

    static func encode(_ image: CGImage, type: UTType, options: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CanvasDocumentError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CanvasDocumentError.imageEncodingFailed }
        return data as Data
    }
}
