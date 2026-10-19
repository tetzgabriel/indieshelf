// The indieshelf app icon, drawn in code (macOS grid: a rounded square 824/1024 wide, centered).
// build.sh runs this to make AppIcon.icns, so the repo needs no image files for it.
import AppKit

func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func draw(in canvas: NSRect) {
    let k = canvas.width / 1024
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = rgb(0x000000, 0.28); shadow.shadowBlurRadius = 20 * k; shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.set()
    rgb(0x2f6fed).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [rgb(0x7cc4ff), rgb(0x3b82f6), rgb(0x2457d6)])!.draw(in: body, angle: -90)
    // soft light from the top
    NSGradient(colors: [rgb(0xffffff, 0.28), rgb(0xffffff, 0)])!.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: 400 * k, weight: .medium)
    let symbol = NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let white = NSImage(size: symbol.size, flipped: false) { r in symbol.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
    let glyph = NSRect(x: body.midX - symbol.size.width / 2, y: body.midY - symbol.size.height / 2 - 12 * k, width: symbol.size.width, height: symbol.size.height)
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = rgb(0x0b2a7a, 0.35); glyphShadow.shadowBlurRadius = 18 * k; glyphShadow.shadowOffset = NSSize(width: 0, height: -8 * k)
    glyphShadow.set()
    white.draw(in: glyph)
    NSGraphicsContext.restoreGraphicsState()
}

func png(pixels: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// AppIcon.iconset → AppIcon.icns, each size drawn on its own so small ones stay crisp.
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let set = out + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    png(pixels: size, to: "\(set)/icon_\(size)x\(size).png")
    png(pixels: size * 2, to: "\(set)/icon_\(size)x\(size)@2x.png")
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set, "-o", out + "/AppIcon.icns"]
try! iconutil.run(); iconutil.waitUntilExit()
try? FileManager.default.removeItem(atPath: set)
print("wrote \(out)/AppIcon.icns")
