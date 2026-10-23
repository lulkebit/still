import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: make_icon.swift <iconset-directory>")
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func renderIcon(size: Int, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor(srgbRed: 0.34, green: 0.42, blue: 0.36, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: CGFloat(size) * 0.23, yRadius: CGFloat(size) * 0.23).fill()

    let fontSize = CGFloat(size) * 0.49
    let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(srgbRed: 0.97, green: 0.96, blue: 0.91, alpha: 1),
        .kern: -fontSize * 0.06
    ]
    let mark = "s." as NSString
    let markSize = mark.size(withAttributes: attributes)
    let textRect = NSRect(
        x: (CGFloat(size) - markSize.width) / 2,
        y: (CGFloat(size) - markSize.height) / 2 - CGFloat(size) * 0.01,
        width: markSize.width + 2,
        height: markSize.height + 1
    )
    mark.draw(in: textRect, withAttributes: attributes)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url, options: .atomic)
}

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (size, name) in variants { try renderIcon(size: size, to: outputDirectory.appendingPathComponent(name)) }
