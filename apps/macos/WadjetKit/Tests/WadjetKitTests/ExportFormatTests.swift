import Testing
import Foundation
import UniformTypeIdentifiers
@testable import WadjetKit

struct ExportFormatTests {
    // Proves Export's starting format: an opened image keeps its own format
    // when offered, HDR falls to HEIC and everything else to PNG.
    @Test(arguments: [
        ("photo.jpg", false, UTType.jpeg), ("photo.JPEG", false, .jpeg),
        ("shot.png", false, .png), ("a.heic", false, .heic),
        ("scan.tiff", false, .png), ("scan.tiff", true, .heic),
        (nil, true, .heic), (nil, false, .png),
    ] as [(String?, Bool, UTType)])
    func exportType(name: String?, hdr: Bool, expected: UTType) {
        let source = name.map { URL(fileURLWithPath: "/tmp/\($0)") }
        #expect(CanvasImageCodec.exportType(source: source, hdr: hdr) == expected)
    }
}
