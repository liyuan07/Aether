import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        let inset = CGFloat(pixels) * 0.065
        let tile = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: CGFloat(pixels) * 0.205, yRadius: CGFloat(pixels) * 0.205)
        let gradient = NSGradient(colors: [NSColor(srgbRed: 0.30, green: 0.48, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.45, green: 0.25, blue: 0.82, alpha: 1)])!
        gradient.draw(in: tile, angle: -65)
        let symbol = NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: CGFloat(pixels) * 0.56, weight: .medium))!
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: symbol.size).fill()
        symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()
        let w = CGFloat(pixels) * 0.65
        let h = w * symbol.size.height / symbol.size.width
        tinted.draw(in: NSRect(x: (CGFloat(pixels) - w) / 2, y: (CGFloat(pixels) - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        let filename = "Aether-\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "Li Yuan", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
