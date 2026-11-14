import AppKit
import DiffCore

@MainActor
enum Icons {
    /// Two panes joined by a curve: the Fluid layout.
    static let fluidLayout: NSImage = {
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 1.5, width: 5, height: 13), xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(roundedRect: NSRect(x: 14, y: 1.5, width: 5, height: 13), xRadius: 1.5, yRadius: 1.5).fill()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 6.5, y: 4))
            p.curve(to: NSPoint(x: 13.5, y: 12), controlPoint1: NSPoint(x: 10.5, y: 4), controlPoint2: NSPoint(x: 9.5, y: 12))
            p.lineWidth = 1.8
            p.lineCapStyle = .round
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Fluid"
        return img
    }()

    /// Two panes side by side: the Blocks layout.
    static let blocksLayout: NSImage = {
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 1.5, width: 7, height: 13), xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(roundedRect: NSRect(x: 11, y: 1.5, width: 7, height: 13), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Blocks"
        return img
    }()

    private static var tiles: [String: NSImage] = [:]

    /// A small rounded tile with a status symbol, used in the folder sidebar.
    static func statusTile(_ status: FolderEntry.Status, size: CGFloat = 18) -> NSImage {
        let key = "\(status)-\(size)"
        if let t = tiles[key] { return t }
        let symbol: String
        switch status {
        case .different: symbol = "pencil"
        case .onlyRight: symbol = "plus"
        case .onlyLeft: symbol = "minus"
        case .identical: symbol = "equal"
        case .pending: symbol = "ellipsis"
        }
        let colors = Theme.colors(for: status)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: size * 0.24, yRadius: size * 0.24)
            (colors?.inline ?? Theme.foldPill).setFill()
            path.fill()
            let tint = colors?.marker ?? Theme.secondaryText
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            if let s = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let sz = s.size
                s.draw(in: NSRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width, height: sz.height))
            }
            return true
        }
        tiles[key] = img
        return img
    }
}
