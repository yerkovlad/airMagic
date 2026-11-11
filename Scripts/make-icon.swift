import AppKit

// Draws the app icon: the case, upright, on a dark tile, with a red pointer dot.
func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tile = NSBezierPath(roundedRect: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88), xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(white: 0.16, alpha: 1), ending: NSColor(white: 0.05, alpha: 1))!.draw(in: tile, angle: -90)
    let w = s * 0.3, h = s * 0.4
    let body = NSBezierPath(roundedRect: NSRect(x: s / 2 - w / 2, y: s * 0.24, width: w, height: h), xRadius: w * 0.42, yRadius: w * 0.42)
    NSColor.white.setFill(); body.fill()
    NSColor(white: 0.8, alpha: 1).setStroke()
    let seam = NSBezierPath(); seam.move(to: NSPoint(x: s / 2 - w / 2 + 2, y: s * 0.24 + h * 0.66)); seam.line(to: NSPoint(x: s / 2 + w / 2 - 2, y: s * 0.24 + h * 0.66))
    seam.lineWidth = max(1, s * 0.008); seam.stroke()
    NSColor.systemRed.setFill()
    NSBezierPath(ovalIn: NSRect(x: s * 0.66, y: s * 0.66, width: s * 0.13, height: s * 0.13)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try render(px).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
