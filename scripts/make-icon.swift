// Draws the app icon and writes an .icns file.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func draw(_ s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024
    // Squircle-ish body inside the standard 824pt grid.
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = hex(0x2A0E5C, 0.35)
    shadow.shadowBlurRadius = 24 * u
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
    shadow.set()
    hex(0x8B46F0).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [hex(0xA46BFF), hex(0x6B2FD6)])!.draw(in: shape, angle: -70)

    // A sheet folded in two: each half is a page sheared away from the crease.
    let pageW = 300 * u, pageH = 520 * u, crease = 512 * u, base = 262 * u, slope: CGFloat = 0.16
    func page(_ side: CGFloat, _ fill: NSColor, _ bands: [(Int, NSColor)]) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.transformStruct = NSAffineTransformStruct(m11: 1, m12: -side * slope, m21: 0, m22: 1, tX: crease, tY: base)
        t.concat()
        let rect = NSRect(x: side < 0 ? -pageW : 0, y: 0, width: pageW, height: pageH)
        let r: CGFloat = 34 * u
        // Round only the outer corners so the halves meet in a straight crease.
        let path = NSBezierPath()
        let outer = side < 0 ? rect.minX : rect.maxX, inner = side < 0 ? rect.maxX : rect.minX
        let dir: CGFloat = side < 0 ? 1 : -1
        path.move(to: NSPoint(x: inner, y: rect.minY))
        path.line(to: NSPoint(x: outer + dir * r, y: rect.minY))
        path.curve(to: NSPoint(x: outer, y: rect.minY + r), controlPoint1: NSPoint(x: outer, y: rect.minY), controlPoint2: NSPoint(x: outer, y: rect.minY))
        path.line(to: NSPoint(x: outer, y: rect.maxY - r))
        path.curve(to: NSPoint(x: outer + dir * r, y: rect.maxY), controlPoint1: NSPoint(x: outer, y: rect.maxY), controlPoint2: NSPoint(x: outer, y: rect.maxY))
        path.line(to: NSPoint(x: inner, y: rect.maxY))
        path.close()
        fill.setFill()
        path.fill()
        path.addClip()
        for i in 0..<7 {
            let y = rect.maxY - CGFloat(64 + i * 66) * u
            if let band = bands.first(where: { $0.0 == i }) {
                band.1.setFill()
                NSRect(x: rect.minX, y: y - 25 * u, width: pageW, height: 66 * u).fill()
            }
            hex(0x3B3550, 0.26).setFill()
            let w = pageW * (i % 3 == 0 ? 0.58 : (i % 3 == 1 ? 0.74 : 0.46))
            let x = side < 0 ? rect.minX + 34 * u : rect.minX + 30 * u
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w - 34 * u, height: 16 * u), xRadius: 8 * u, yRadius: 8 * u).fill()
        }
        // Shade toward the crease for depth.
        let shade = NSGradient(colors: [hex(0x2A0E5C, 0), hex(0x2A0E5C, side < 0 ? 0.10 : 0.16)])!
        shade.draw(in: rect, angle: side < 0 ? 0 : 180)
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = hex(0x1E0848, 0.45)
    drop.shadowBlurRadius = 30 * u
    drop.shadowOffset = NSSize(width: 0, height: -14 * u)
    drop.set()
    page(-1, hex(0xFFFFFF), [(1, hex(0x6C99E5, 0.38)), (4, hex(0xD4706A, 0.40))])
    page(1, hex(0xF6F2FF), [(1, hex(0x6C99E5, 0.38)), (3, hex(0x67C065, 0.45)), (4, hex(0x67C065, 0.45))])
    NSGraphicsContext.restoreGraphicsState()
    // The crease.
    hex(0x2A0E5C, 0.22).setFill()
    NSRect(x: crease - 1.5 * u, y: base, width: 3 * u, height: pageH).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Twofold-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(out)")
