import AppKit
import DiffCore

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Every colour the app draws with. No colour literal appears outside this file.
enum Theme {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func hex(_ light: UInt32, _ dark: UInt32) -> NSColor {
        dynamic(NSColor(hex: light), NSColor(hex: dark))
    }

    // Surfaces
    static let chrome = hex(0xF3F0FA, 0x221F29)
    static let paneBackground = hex(0xFFFFFF, 0x1B1A1F)
    static let ribbonBackground = hex(0xFBFAFD, 0x1F1E24)
    static let separator = hex(0xE2DEEA, 0x35323D)

    // Text
    static let text = hex(0x1D1D21, 0xE4E3EA)
    static let secondaryText = hex(0x77757F, 0x9C9AA6)
    static let lineNumber = hex(0xA4A2AD, 0x66646F)
    static let foldText = hex(0xA9A7B1, 0x74727C)
    static let foldLine = hex(0xDFDDE5, 0x393741)
    static let foldPill = hex(0xE6E4EB, 0x34323B)
    static let invisible = hex(0xB3B1BA, 0x5D5B65)
    static let textSelection = dynamic(NSColor(hex: 0x8B46F0, alpha: 0.22), NSColor(hex: 0xA673FF, alpha: 0.35))

    // Accent
    static let accent = hex(0x8B46F0, 0x9D63FF)
    static let accentSoft = hex(0xEBE1FD, 0x3A2C57)

    // Overview strip
    static let thumb = dynamic(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.13))
    static let thumbBorder = dynamic(NSColor(white: 0, alpha: 0.18), NSColor(white: 1, alpha: 0.22))

    struct ChangeColors {
        let body: NSColor
        let bodyCurrent: NSColor
        let gutter: NSColor
        let gutterCurrent: NSColor
        let inline: NSColor
        let inlineCurrent: NSColor
        let stroke: NSColor
        let marker: NSColor
        let band: NSColor
    }

    static let added = ChangeColors(
        body: hex(0xEFF9EC, 0x1A2B1E),
        bodyCurrent: hex(0xDDF3D7, 0x213D28),
        gutter: hex(0xE2F5DE, 0x203626),
        gutterCurrent: hex(0x5DBA60, 0x3B9449),
        inline: hex(0xC5EBBD, 0x2B5A33),
        inlineCurrent: hex(0xACE0A2, 0x33703E),
        stroke: hex(0x67C065, 0x4EAE5C),
        marker: hex(0x3A9C3D, 0x6BCB78),
        band: dynamic(NSColor(hex: 0x67C065, alpha: 0.10), NSColor(hex: 0x4EAE5C, alpha: 0.12))
    )

    static let removed = ChangeColors(
        body: hex(0xFDEFED, 0x2F1D1D),
        bodyCurrent: hex(0xF7DAD6, 0x472625),
        gutter: hex(0xF9E3E0, 0x3B2323),
        gutterCurrent: hex(0xCF6A63, 0xB04E49),
        inline: hex(0xF4C6C0, 0x67302E),
        inlineCurrent: hex(0xEDAAA2, 0x7D3936),
        stroke: hex(0xD4706A, 0xCF5F5B),
        marker: hex(0xC3433B, 0xE5766F),
        band: dynamic(NSColor(hex: 0xD4706A, alpha: 0.10), NSColor(hex: 0xCF5F5B, alpha: 0.12))
    )

    static let modified = ChangeColors(
        body: hex(0xF0F5FE, 0x1B2435),
        bodyCurrent: hex(0xDDE8FC, 0x22314D),
        gutter: hex(0xE4EDFD, 0x202D45),
        gutterCurrent: hex(0x6493E5, 0x3F6CBA),
        inline: hex(0xC9DBFB, 0x2D4675),
        inlineCurrent: hex(0xADC8F7, 0x36558E),
        stroke: hex(0x6C99E5, 0x5A8DDF),
        marker: hex(0x3E70CE, 0x7EA8F0),
        band: dynamic(NSColor(hex: 0x6C99E5, alpha: 0.10), NSColor(hex: 0x5A8DDF, alpha: 0.12))
    )

    static func colors(for kind: DiffBlock.Kind) -> ChangeColors {
        switch kind {
        case .added: added
        case .removed: removed
        case .modified, .equal: modified
        }
    }

    static func colors(for status: FolderEntry.Status) -> ChangeColors? {
        switch status {
        case .different: modified
        case .onlyRight: added
        case .onlyLeft: removed
        case .identical, .pending: nil
        }
    }
}
