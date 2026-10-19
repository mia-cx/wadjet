import CoreGraphics
import Foundation
import ImageIO
import Testing
import WadjetKit

struct MagnifyRendererTests {
    /// the flat options the pixel tests use: no glass, no leader, no border
    private func opts(_ shape: MagnifierShape = .rectangle,
                      scaling: MagnifyScaling = .nearestNeighbour) -> MagnifierOptions {
        MagnifierOptions(shape: shape, leader: false, glass: false, scaling: scaling)
    }
    private func style() -> AnnotationStyle {
        .init(colour: .init(red: 1, green: 0, blue: 0, alpha: 1), width: 2)
    }

    // Proves nearest-neighbour scaling: every source pixel lands as an exact
    // 4×4 block in the magnifier — 8×8 px at flatten scale 2.
    @Test func nearestNeighbourBlocks() throws {
        // 16 distinct opaque colours, one per source pixel
        var sourcePixels: [UInt8] = []
        for i in 0..<16 {
            sourcePixels += [UInt8(i * 16), UInt8(255 - i * 16), UInt8((i * 37) % 256), 255]
        }
        let source = try image(width: 4, height: 4, pixels: sourcePixels)
        // the source sits at (0,0)-(4,4); the magnifier frame at (10,0)
        let m = Magnifier(source: CGRect(x: 0, y: 0, width: 4, height: 4),
                          frame: CGRect(x: 10, y: 0, width: 16, height: 16), zoom: 4,
                          options: opts())
        let document = CanvasDocument(
            layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 4, height: 4), scaleFactor: 1)],
            crop: CGRect(x: 10, y: 0, width: 16, height: 16),
            layerStack: LayerStack([Annotation(kind: .magnify(m), style: style())]),
            displayImages: [1: source])
        let pixels = try linearPixels(document.flatten(scale: 2))
        // memory rows are top-down in both images: block row sy reads source
        // row sy, each source pixel spread over an 8×8 block at scale 2
        for sy in 0..<4 { for sx in 0..<4 {
            let src = sy * 4 + sx
            let expected: [Float] = [lin(UInt8(src * 16)), lin(UInt8(255 - src * 16)),
                                     lin(UInt8((src * 37) % 256)), 1]
            for by in 0..<8 { for bx in 0..<8 {
                let i = 4 * ((sy * 8 + by) * 32 + sx * 8 + bx)
                let p = Array(pixels[i..<i + 3])
                for c in 0..<3 {
                    #expect(abs(p[c] - expected[c]) < 0.002,
                            "block (\(sx), \(sy)) pixel (\(bx), \(by))")
                }
            } }
        } }
    }

    // Proves Lanczos softens a hard edge where nearest-neighbour keeps it hard.
    @Test func lanczosSoftensEdges() throws {
        let edge: [UInt8] = (0..<4).flatMap { _ in
            (0..<4).flatMap { x -> [UInt8] in [x < 2 ? 0 : 255, x < 2 ? 0 : 255, x < 2 ? 0 : 255, 255] }
        }
        let source = try image(width: 4, height: 4, pixels: edge)
        func flattened(_ scaling: MagnifyScaling) throws -> [Float] {
            let m = Magnifier(source: CGRect(x: 0, y: 0, width: 4, height: 4),
                              frame: CGRect(x: 10, y: 0, width: 16, height: 16), zoom: 4,
                              options: opts(scaling: scaling))
            let document = CanvasDocument(
                layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 4, height: 4), scaleFactor: 1)],
                crop: CGRect(x: 10, y: 0, width: 16, height: 16),
                layerStack: LayerStack([Annotation(kind: .magnify(m), style: style())]),
                displayImages: [1: source])
            return try linearPixels(document.flatten(scale: 1))
        }
        let near = try flattened(.nearestNeighbour), lanc = try flattened(.lanczos)
        // the edge between source columns 1 and 2 falls on output columns 7/8
        func r(_ px: [Float], _ x: Int, _ y: Int) -> Float { px[4 * (y * 16 + x)] }
        for y in [0, 8] {
            #expect(r(near, 7, y) == 0 || r(near, 7, y) == 1)
            #expect(r(lanc, 7, y) > 0.05 && r(lanc, 7, y) < 0.95,
                    "Lanczos kept a hard edge at column 7")
            // far from the edge both agree with the source
            #expect(abs(r(lanc, 2, y) - 0) < 0.01)
            #expect(abs(r(lanc, 14, y) - 1) < 0.01)
        }
    }

    // Proves glass only touches the rim: the centre pixel matches plain
    // content, the top rim brightens.
    @Test func glassLightsOnlyTheRim() throws {
        let source = try solidImage([0.2, 0.2, 0.2, 1], width: 8, height: 8)
        func flattened(glass: Bool) throws -> [Float] {
            var o = opts()
            o.glass = glass
            // the viewport is the 10×10 source at zoom 4 — fully covered by
            // the 16×16 display, so even the rim reads real pixels
            let m = Magnifier(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                              frame: CGRect(x: 20, y: 0, width: 40, height: 40), zoom: 4,
                              options: o)
            let document = CanvasDocument(
                layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 16, height: 16), scaleFactor: 1)],
                crop: CGRect(x: 20, y: 0, width: 40, height: 40),
                layerStack: LayerStack([Annotation(kind: .magnify(m), style: style())]),
                displayImages: [1: source])
            return try linearPixels(document.flatten(scale: 1))
        }
        let off = try flattened(glass: false), on = try flattened(glass: true)
        func r(_ px: [Float], _ x: Int, _ y: Int) -> Float { px[4 * (y * 40 + x)] }
        // the centre pixel — deep inside, glass copies it unchanged
        #expect(r(on, 20, 20) == r(off, 20, 20))
        // a pixel on the top rim (memory row 0 is the image's top edge) is brighter
        #expect(r(on, 20, 0) > r(off, 20, 0))
    }

    // Proves a viewport straddling two displays composites both sources.
    @Test func compositesTwoDisplays() throws {
        // left display (0,0)-(4,4) red, right display (4,0)-(8,4) blue
        let m = Magnifier(source: CGRect(x: 2, y: 0, width: 4, height: 4),
                          frame: CGRect(x: 20, y: 0, width: 16, height: 16), zoom: 4,
                          options: opts())
        let document = CanvasDocument(
            layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 4, height: 4), scaleFactor: 1),
                     .init(id: 2, frame: CGRect(x: 4, y: 0, width: 4, height: 4), scaleFactor: 1)],
            crop: CGRect(x: 20, y: 0, width: 16, height: 16),
            layerStack: LayerStack([Annotation(kind: .magnify(m), style: style())]),
            displayImages: [1: try solidImage([1, 0, 0, 1], width: 4, height: 4),
                            2: try solidImage([0, 0, 1, 1], width: 4, height: 4)])
        // the viewport is the source (2,0)-(6,0): its left half on the red
        // display, right half on the blue
        let px = try linearPixels(document.flatten(scale: 1))
        func p(_ x: Int, _ y: Int) -> [Float] { Array(px[4 * (y * 16 + x)..<4 * (y * 16 + x) + 3]) }
        #expect(p(3, 8) == [1, 0, 0])
        #expect(p(12, 8) == [0, 0, 1])
    }

    // Proves the flattened Magnify look against the recorded golden: a 3×3
    // sheet — columns superellipse/circle/rectangle, rows plain / white
    // border / glass — over a mid-dark display with fine detail in every
    // source's viewport, leaders on, nearest-neighbour.
    @Test func flattenedMatchesGolden() throws {
        let display = try goldenScene() // 760×560 pt at scale 2
        var annotations: [Annotation] = []
        let shapes: [MagnifierShape] = [.superellipse, .circle, .rectangle]
        for row in 0..<3 { for col in 0..<3 {
            let fx = CGFloat([30, 270, 510][col]), fy = CGFloat([400, 215, 30][row])
            // the source sits 50 pt right of the frame's right edge, 30 pt
            // above its centre — in the column gap
            let cx = fx + 140 + 50, cy = fy + 70 + 30
            let o = MagnifierOptions(
                shape: shapes[col], leader: true, glass: row == 2,
                border: row == 1 ? RGBAColour(red: 1, green: 1, blue: 1, alpha: 1) : nil,
                scaling: .nearestNeighbour)
            let m = Magnifier(source: CGRect(x: cx - 14, y: cy - 14, width: 28, height: 28),
                              frame: CGRect(x: fx, y: fy, width: 140, height: 140),
                              zoom: nil, options: o)
            annotations.append(Annotation(kind: .magnify(m), style: style()))
        } }
        let document = CanvasDocument(
            layout: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 760, height: 560), scaleFactor: 2)],
            crop: CGRect(x: 0, y: 0, width: 760, height: 560),
            layerStack: LayerStack(annotations), displayImages: [1: display])
        let flattened = try document.flatten(scale: 2)
        if ProcessInfo.processInfo.environment["WADJET_RECORD_FIXTURES"] == "1" {
            try record(flattened, name: "magnify-flattened")
            return
        }
        try expectFixture(flattened, name: "magnify-flattened", tolerance: 0.02)
    }

    /// the golden sheet's backdrop: a mid-dark display with 1-pt diagonal
    /// hairlines every 6 pt and a fixed set of small colourful details inside
    /// each source's 35×35 pt viewport
    private func goldenScene() throws -> CGImage {
        let w = 1520, h = 1120 // 760×560 pt at scale 2
        var px = [UInt8](repeating: 0, count: w * h * 4)
        func plot(_ x: Int, _ y: Int, _ c: [UInt8]) {
            guard (0..<w).contains(x), (0..<h).contains(y) else { return }
            let i = 4 * (y * w + x)
            px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255
        }
        for y in 0..<h { for x in 0..<w {
            // #2B2F36, with lighter 2-px diagonals every 12 px (1 pt per 6 pt)
            let base: [UInt8] = (x + y) % 12 < 2 ? [62, 67, 76] : [43, 47, 54]
            plot(x, y, base)
        } }
        // pt coords in, pixel rows out (memory rows run top-down)
        func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ c: [UInt8]) {
            for py in (h - Int(y1 * 2))..<(h - Int(y0 * 2)) {
                for px_ in Int(x0 * 2)..<Int(x1 * 2) { plot(px_, py, c) }
            }
        }
        func disc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: [UInt8]) {
            for py in 0..<h { for px_ in 0..<w {
                let dx = CGFloat(px_) / 2 - cx, dy = (CGFloat(h) - CGFloat(py)) / 2 - cy
                if dx * dx + dy * dy <= r * r { plot(px_, py, c) }
            } }
        }
        // one detail cluster per source viewport: checker, disc, square, lines
        for fy in [CGFloat(400), 215, 30] { for fx in [CGFloat(30), 270, 510] {
            let cx = fx + 190, cy = fy + 100
            // a 1-px checker patch, 12 px wide (6 pt)
            for py in 0..<12 { for x_ in 0..<12 {
                plot(Int(cx * 2) - 14 + x_, h - Int(cy * 2) - 18 + py,
                     (x_ + py) % 2 == 0 ? [255, 255, 255] : [20, 20, 20])
            } }
            disc(cx - 9, cy - 6, 4, [255, 149, 0])      // an orange disc
            rect(cx + 2, cy - 12, cx + 10, cy - 4, [0, 199, 190]) // a teal square
            rect(cx - 14, cy + 12, cx - 4, cy + 13, [52, 199, 89]) // a green 1-pt line
            rect(cx + 13, cy + 2, cx + 14, cy + 12, [191, 90, 242]) // a purple 1-pt line
        } }
        return try image(width: w, height: h, pixels: px)
    }

    /// writes the flattened render into the source tree's Fixtures as a PNG —
    /// via an 8-bit sRGB bitmap so the glass rim's >1 headroom clamps
    /// deterministically instead of going through a 16-bit wide-gamut encode
    private func record(_ image: CGImage, name: String) throws {
        let srgb = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        srgb.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let png = try #require(srgb.makeImage())
        // #filePath anchors at this test file; Fixtures sits beside it
        let dir = URL(filePath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, png, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}

private func image(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

private func solidImage(_ colour: [CGFloat], width: Int = 8, height: Int = 8) throws -> CGImage {
    try image(width: width, height: height,
        pixels: Array(repeating: colour.map { UInt8($0 * 255) }, count: width * height).flatMap { $0 })
}

/// an 8-bit sRGB value as extended-linear sRGB, the space linearPixels reads
private func lin(_ v: UInt8) -> Float {
    let c = Float(v) / 255
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

private func linearPixels(_ image: CGImage) throws -> [Float] {
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 32,
        bytesPerRow: image.width * 16, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setEDRTargetHeadroom(0)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data).assumingMemoryBound(to: Float.self)
    return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
}

private func expectFixture(_ actual: CGImage, name: String, tolerance: Float) throws {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let expected = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(actual.width == expected.width && actual.height == expected.height)
    // a PNG can't hold the >1 headroom a glass rim adds to bright pixels —
    // compare within the fixture's clamped range
    let rendered = try linearPixels(actual).map { min(max($0, 0), 1) }
    let fixture = try linearPixels(expected)
    let difference = zip(rendered, fixture).map { abs($0 - $1) }.max() ?? 0
    #expect(difference <= tolerance, "\(name): max component difference \(difference)")
}
