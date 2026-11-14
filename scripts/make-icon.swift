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

    // Two panes.
    let paneW = 250 * u, paneH = 560 * u, top = 230 * u
    let leftPane = NSRect(x: 190 * u, y: top, width: paneW, height: paneH)
    let rightPane = NSRect(x: 584 * u, y: top, width: paneW, height: paneH)
    for p in [leftPane, rightPane] {
        hex(0xFFFFFF, 0.96).setFill()
        NSBezierPath(roundedRect: p, xRadius: 40 * u, yRadius: 40 * u).fill()
    }
    // Text lines and change bands.
    func lines(_ pane: NSRect, _ bands: [(Int, NSColor)]) {
        for i in 0..<7 {
            let y = pane.maxY - CGFloat(70 + i * 68) * u
            if let band = bands.first(where: { $0.0 == i }) {
                band.1.setFill()
                NSRect(x: pane.minX, y: y - 26 * u, width: pane.width, height: 68 * u).fill()
            }
            hex(0x3B3550, 0.28).setFill()
            let w = pane.width * (i % 3 == 0 ? 0.62 : (i % 3 == 1 ? 0.78 : 0.48))
            NSBezierPath(roundedRect: NSRect(x: pane.minX + 30 * u, y: y, width: w - 30 * u, height: 16 * u), xRadius: 8 * u, yRadius: 8 * u).fill()
        }
    }
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: leftPane, xRadius: 40 * u, yRadius: 40 * u).addClip()
    lines(leftPane, [(1, hex(0x6C99E5, 0.35)), (4, hex(0xD4706A, 0.38))])
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rightPane, xRadius: 40 * u, yRadius: 40 * u).addClip()
    lines(rightPane, [(1, hex(0x6C99E5, 0.35)), (3, hex(0x67C065, 0.42)), (4, hex(0x67C065, 0.42))])
    NSGraphicsContext.restoreGraphicsState()

    // Connectors.
    func connector(_ y1: CGFloat, _ y2: CGFloat, _ c: NSColor) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: leftPane.maxX, y: y1))
        p.curve(to: NSPoint(x: rightPane.minX, y: y2), controlPoint1: NSPoint(x: 512 * u, y: y1), controlPoint2: NSPoint(x: 512 * u, y: y2))
        p.lineWidth = 22 * u
        p.lineCapStyle = .round
        c.setStroke()
        p.stroke()
    }
    let row: (Int) -> CGFloat = { leftPane.maxY - CGFloat(70 + $0 * 68) * u + 8 * u }
    connector(row(1), row(1), hex(0xFFFFFF, 0.9))
    connector(row(4) - 8 * u, row(3) - 42 * u, hex(0xFFFFFF, 0.9))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("VisDiff-\(getpid()).iconset")
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
