// Draws the 1200×630 link preview image (Open Graph / Twitter card) from the site's
// own icon and hero screenshot, so it never drifts from the real app.
// Usage: swift scripts/make-social-card.swift docs/assets/social-card.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "social-card.png"
let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../docs/assets").standardized

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func image(_ name: String) -> NSImage {
    guard let img = NSImage(contentsOf: assets.appendingPathComponent(name)) else {
        FileHandle.standardError.write("missing docs/assets/\(name)\n".data(using: .utf8)!)
        exit(1)
    }
    return img
}

let W: CGFloat = 1200, H: CGFloat = 630
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: the site's light page colour with a soft brand glow.
hex(0xFAF8FE).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()
NSGradient(colors: [hex(0x8B46F0, 0.28), hex(0x8B46F0, 0)])!
    .draw(fromCenter: NSPoint(x: 900, y: 520), radius: 0, toCenter: NSPoint(x: 900, y: 520), radius: 620, options: [])

// Screenshot, bleeding off the right and bottom edges.
let shot = image("hero-light.png")
let shotRect = NSRect(x: 560, y: -90, width: 800, height: 500)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = hex(0x2A0E5C, 0.35)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = NSSize(width: 0, height: -16)
shadow.set()
let clip = NSBezierPath(roundedRect: shotRect, xRadius: 16, yRadius: 16)
hex(0xFFFFFF).setFill()
clip.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
clip.addClip()
shot.draw(in: shotRect)
NSGraphicsContext.restoreGraphicsState()

// Icon and text column.
image("icon.png").draw(in: NSRect(x: 64, y: 440, width: 120, height: 120))

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: NSPoint, width: CGFloat = 480) {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = 0.95
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
        .kern: -size * 0.02,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let h = str.boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin]).height
    str.draw(with: NSRect(x: p.x, y: p.y - h, width: width, height: h), options: [.usesLineFragmentOrigin])
}

text("Twofold", 76, .bold, hex(0x18181B), at: NSPoint(x: 72, y: 410))
text("The prettiest diff\non your Mac.", 44, .semibold, hex(0x3F3F46), at: NSPoint(x: 72, y: 312))
text("Free forever.", 44, .semibold, hex(0x8B46F0), at: NSPoint(x: 72, y: 206))
text("Open source · Files & folders · No subscription", 22, .medium, hex(0x71717A), at: NSPoint(x: 72, y: 110))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
