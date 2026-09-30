import AppKit

// Draw at each native size instead of stretching the small menu-bar image.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func icon(_ pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    context.cgContext.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 88, width: 864, height: 864), xRadius: 194, yRadius: 194)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    NSColor(calibratedRed: 0.13, green: 0.23, blue: 0.63, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.28, blue: 0.72, alpha: 1),
               ending: NSColor(calibratedRed: 0.31, green: 0.49, blue: 0.96, alpha: 1))!.draw(in: tile, angle: 90)

    // A wide, split monitor repeats the menu-bar silhouette, with clear colored regions.
    let screen = NSBezierPath(roundedRect: NSRect(x: 174, y: 348, width: 676, height: 384), xRadius: 46, yRadius: 46)
    NSGraphicsContext.saveGraphicsState()
    let monitorShadow = NSShadow()
    monitorShadow.shadowColor = NSColor(calibratedWhite: 0.05, alpha: 0.25)
    monitorShadow.shadowBlurRadius = 24
    monitorShadow.shadowOffset = NSSize(width: 0, height: -12)
    monitorShadow.set()
    NSColor.white.setFill()
    screen.fill()
    NSGraphicsContext.restoreGraphicsState()
    let content = NSBezierPath(roundedRect: NSRect(x: 201, y: 375, width: 622, height: 330), xRadius: 23, yRadius: 23)
    NSGraphicsContext.saveGraphicsState()
    content.addClip()
    NSGradient(starting: NSColor(calibratedRed: 0.06, green: 0.12, blue: 0.30, alpha: 1),
               ending: NSColor(calibratedRed: 0.11, green: 0.24, blue: 0.49, alpha: 1))!.draw(in: content, angle: 90)
    NSColor(calibratedRed: 0.43, green: 0.87, blue: 0.98, alpha: 1).setFill()
    NSRect(x: 201, y: 375, width: 302, height: 330).fill()
    NSColor.white.setFill()
    NSRect(x: 503, y: 375, width: 18, height: 330).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 487, y: 260, width: 50, height: 103), xRadius: 12, yRadius: 12).fill()
    NSBezierPath(roundedRect: NSRect(x: 398, y: 245, width: 228, height: 30), xRadius: 15, yRadius: 15).fill()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 2 ? "@2x" : ""
        try icon(points * multiplier).write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
