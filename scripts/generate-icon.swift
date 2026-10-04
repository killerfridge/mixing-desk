import AppKit
import Foundation

// Original vector artwork rendered with AppKit; no external artwork or fonts.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(red: 0.065, green: 0.085, blue: 0.095, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 55, y: 55, width: 914, height: 914), xRadius: 206, yRadius: 206).fill()
        for (index, x) in [CGFloat(295), 512, 729].enumerated() {
            NSColor(red: 0.20, green: 0.25, blue: 0.27, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 15, y: 245, width: 30, height: 535), xRadius: 15, yRadius: 15).fill()
            let y: CGFloat = [580, 365, 500][index]
            (index == 1 ? NSColor(red: 0.30, green: 0.80, blue: 0.69, alpha: 1) : NSColor(red: 0.97, green: 0.66, blue: 0.30, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 75, y: y, width: 150, height: 95), xRadius: 22, yRadius: 22).fill()
            NSColor.black.withAlphaComponent(0.4).setFill()
            NSBezierPath(rect: NSRect(x: x - 48, y: y + 43, width: 96, height: 9)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
