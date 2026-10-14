// Draws the Disk Alert app icon and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    let size = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: the shape fills about 80% of the canvas.
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.19, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 1))?.draw(in: shape, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke()
    shape.lineWidth = max(1, size * 0.004)
    shape.stroke()

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.34, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedRed: 0.30, green: 0.64, blue: 1, alpha: 1)]))
    if let symbol = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + size * 0.02, width: s.width, height: s.height))
    }

    // Small status dot.
    let dot = size * 0.09
    let dotRect = NSRect(x: rect.maxX - dot * 2.1, y: rect.maxY - dot * 2.1, width: dot, height: dot)
    NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.35, alpha: 1).setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        if let data = render(base * scale) {
            try? data.write(to: out.appendingPathComponent(name))
        }
    }
}
