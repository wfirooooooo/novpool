// Build NovPoolApp/Assets/AppIcon.icns from NovPoolApp/Assets/blackhole-app-1024.png.
//
// Avoids iconutil (in restricted sandboxes it hits blocked system services and falsely
// reports "Invalid Iconset"). Assembles the .icns container directly: header + typed PNG chunks.
//
// Run:
//   swift scripts/make-app-icon.swift
import CoreGraphics
import Foundation
import ImageIO

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appending(path: "NovPoolApp/Assets/blackhole-app-1024.png")
let outputURL = root.appending(path: "NovPoolApp/Assets/AppIcon.icns")

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot read source image")
}

func resized(_ image: CGImage, to pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return context.makeImage()!
}

func pngData(for image: CGImage) -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        fatalError("Cannot create PNG destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("PNG encode failed")
    }
    return data as Data
}

func typeCode(_ raw: String) -> UInt32 {
    assert(raw.utf8.count == 4)
    var value: UInt32 = 0
    for byte in raw.utf8 {
        value = (value << 8) | UInt32(byte)
    }
    return value
}

func appendBE32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

/// Pixel size → icns type code (PNG-encoded types, same as iconutil).
let sizes: [(pixels: Int, type: String)] = [
    (16, "icp4"), (32, "icp5"), (64, "icp6"), (128, "ic07"), (256, "ic08"),
    (512, "ic09"), (1024, "ic10"),
    (32, "ic11"), (64, "ic12"), (256, "ic13"), (512, "ic14"),
]

var chunks = Data()
for (pixels, type) in sizes {
    let png = pngData(for: resized(master, to: pixels))
    appendBE32(typeCode(type), to: &chunks)
    appendBE32(UInt32(8 + png.count), to: &chunks)
    chunks.append(png)
}

var icns = Data()
icns.append(contentsOf: "icns".utf8)
appendBE32(UInt32(8 + chunks.count), to: &icns)
icns.append(chunks)

try icns.write(to: outputURL, options: .atomic)
print("Wrote \(outputURL.path(percentEncoded: false)) (\(icns.count) bytes, \(sizes.count) sizes)")
