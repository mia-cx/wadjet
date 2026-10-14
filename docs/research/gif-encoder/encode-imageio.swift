// encode-imageio.swift
// Encodes a directory of PNG frames into an animated GIF using ImageIO.
// Usage: encode-imageio <frame-dir> <out.gif> [fps]
// Per-frame delay = 1/fps, loop count 0 (infinite). No custom quantization.

import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: encode-imageio <frame-dir> <out.gif> [fps]\n", stderr)
    exit(2)
}
let frameDir = args[1]
let outPath = args[2]
let fps = args.count > 3 ? Double(args[3])! : 15.0

let fm = FileManager.default
let names = try fm.contentsOfDirectory(atPath: frameDir)
    .filter { $0.hasSuffix(".png") }
    .sorted()
guard !names.isEmpty else {
    fputs("no PNG frames in \(frameDir)\n", stderr)
    exit(1)
}

let outURL = URL(fileURLWithPath: outPath) as CFURL
guard let dest = CGImageDestinationCreateWithURL(
    outURL, UTType.gif.identifier as CFString, names.count, nil
) else {
    fputs("could not create image destination\n", stderr)
    exit(1)
}

CGImageDestinationSetProperties(dest, [
    kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFLoopCount: 0
    ] as CFDictionary
] as CFDictionary)

let frameProps = [
    kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: 1.0 / fps
    ] as CFDictionary
] as CFDictionary

for name in names {
    let url = URL(fileURLWithPath: frameDir + "/" + name) as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fputs("could not load \(name)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(dest, img, frameProps)
}

guard CGImageDestinationFinalize(dest) else {
    fputs("finalize failed\n", stderr)
    exit(1)
}
print("\(names.count) frames -> \(outPath)")
