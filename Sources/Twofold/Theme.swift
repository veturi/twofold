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

    // Find
    static let findMatch = dynamic(NSColor(hex: 0xFFD60A, alpha: 0.45), NSColor(hex: 0xFFD60A, alpha: 0.28))
    static let findCurrent = dynamic(NSColor(hex: 0xFF9F0A, alpha: 0.75), NSColor(hex: 0xFF9F0A, alpha: 0.62))
    static let findTick = hex(0xE0A800, 0xD9A400)

    // Accent
    static let accent = hex(0x8B46F0, 0x9D63FF)
    static let accentSoft = hex(0xEBE1FD, 0x3A2C57)

    // Start window. Its pages sit on the ribbon artwork, so surfaces are translucent.
    static func alpha(_ light: UInt32, _ la: CGFloat, _ dark: UInt32, _ da: CGFloat) -> NSColor {
        dynamic(NSColor(hex: light, alpha: la), NSColor(hex: dark, alpha: da))
    }
    static let welcomeText = hex(0x1D1D21, 0xFFFFFF)
    static let welcomeSecondary = alpha(0x1D1D21, 0.62, 0xFFFFFF, 0.64)
    static let welcomeTertiary = alpha(0x1D1D21, 0.45, 0xFFFFFF, 0.42)
    static let welcomeLink = hex(0x8B46F0, 0xC4A2FF)
    static let welcomeSidebar = alpha(0xFFFFFF, 0.62, 0x0A0714, 0.66)
    static let welcomeSidebarEdge = alpha(0x000000, 0.06, 0xFFFFFF, 0.08)
    static let welcomeSelection = alpha(0x8B46F0, 0.12, 0xFFFFFF, 0.09)
    static let welcomeHover = alpha(0x8B46F0, 0.06, 0xFFFFFF, 0.05)
    static let welcomeCard = alpha(0xFFFFFF, 0.72, 0xFFFFFF, 0.055)
    static let welcomeCardHover = alpha(0xFFFFFF, 0.92, 0xFFFFFF, 0.09)
    static let welcomePanel = alpha(0xFFFFFF, 0.66, 0x0A0714, 0.36)
    static let welcomeCardStroke = alpha(0x000000, 0.08, 0xFFFFFF, 0.11)
    static let welcomeWellStroke = alpha(0x6B2FD6, 0.28, 0xFFFFFF, 0.22)
    static let welcomeDropFill = alpha(0x8B46F0, 0.16, 0x9D63FF, 0.30)
    static let welcomeDropStroke = hex(0x8B46F0, 0xC4A2FF)
    static let welcomeErrorFill = alpha(0xFFF5F4, 0.92, 0x3A1A1E, 0.55)
    static let welcomeChip = alpha(0x000000, 0.05, 0xFFFFFF, 0.07)
    static let welcomeButtonTop = NSColor(hex: 0xA46BFF)
    static let welcomeButtonBottom = NSColor(hex: 0x7B3DE6)
    static let welcomeButtonText = NSColor.white
    static let welcomeGlow = alpha(0x8B46F0, 0.45, 0x8B46F0, 0.7)
    static let welcomeShadow = alpha(0x2A0E5C, 0.10, 0x000000, 0.35)
    static let welcomeHeroStart = NSColor(hex: 0x7B3DF0)
    static let welcomeHeroEnd = NSColor(hex: 0x3A1D7A)
    static let welcomeOnHero = NSColor.white
    static let welcomeOnHeroSecondary = NSColor(white: 1, alpha: 0.78)
    static let welcomeOnHeroChip = NSColor(white: 1, alpha: 0.16)
    static let welcomeStatusGood = hex(0x2E8A57, 0x8FE0B5)
    static let welcomeStatusWarning = hex(0x9A6200, 0xFFD38A)

    /// The colours of the start window's ribbon artwork for one appearance, as Core Graphics colours.
    struct RibbonArt {
        let base: [CGColor]
        /// Soft glows: centre (unit coordinates, top left origin), radius (fraction of the width) and colour.
        let glows: [(x: CGFloat, y: CGFloat, radius: CGFloat, color: CGColor)]
        let strand: NSColor
        let strandOpacity: ClosedRange<CGFloat>
        /// The four coloured bands, as the change colours: modified, accent, added, removed.
        let bands: [NSColor]
        let bandOpacity: CGFloat
    }

    static func ribbonArt(dark: Bool) -> RibbonArt {
        func c(_ v: UInt32, _ a: CGFloat = 1) -> CGColor { NSColor(hex: v, alpha: a).cgColor }
        let bands = [NSColor(hex: 0x5B8CF0), NSColor(hex: 0xA06BFF), NSColor(hex: 0x4CC38A), NSColor(hex: 0xF06A6A)]
        if dark {
            return RibbonArt(
                base: [c(0x0E0B19), c(0x1A1030), c(0x120D22)],
                glows: [(0.62, 0.40, 0.55, c(0x7B3DF0, 0.55)), (0.95, 0.05, 0.45, c(0xC04BE8, 0.30)),
                        (0.30, 1.00, 0.50, c(0x2F5BD8, 0.35)), (0.92, 0.95, 0.35, c(0x2BB38A, 0.16))],
                strand: .white, strandOpacity: 0.035...0.10, bands: bands, bandOpacity: 0.30)
        }
        return RibbonArt(
            base: [c(0xF7F4FD), c(0xEFE7FF), c(0xF4F0FB)],
            glows: [(0.62, 0.40, 0.55, c(0xB58BFF, 0.45)), (0.95, 0.05, 0.45, c(0xF0A8F5, 0.35)),
                    (0.30, 1.00, 0.50, c(0x9DB8FF, 0.40)), (0.92, 0.95, 0.35, c(0x9EE6C6, 0.25))],
            strand: NSColor(hex: 0x6B2FD6), strandOpacity: 0.05...0.13, bands: bands, bandOpacity: 0.22)
    }

    // Overview strip
    static let thumb = dynamic(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.13))
    static let thumbBorder = dynamic(NSColor(white: 0, alpha: 0.18), NSColor(white: 1, alpha: 0.22))

    // Syntax. Chosen to stay readable on the pale change fills as well as the plain pane.
    static func syntax(_ kind: SyntaxKind) -> NSColor {
        switch kind {
        case .keyword, .tag: syntaxKeyword
        case .string: syntaxString
        case .number: syntaxNumber
        case .comment: syntaxComment
        case .type: syntaxType
        case .function: syntaxFunction
        case .attribute: syntaxAttribute
        case .property: syntaxProperty
        }
    }

    static let syntaxKeyword = hex(0xAD3DA4, 0xFF7AB2)
    static let syntaxString = hex(0xC4301C, 0xFF8170)
    static let syntaxNumber = hex(0x2747C7, 0xD0BF69)
    static let syntaxComment = hex(0x6E7A87, 0x7F8C98)
    static let syntaxType = hex(0x0B7285, 0x5DD8FF)
    static let syntaxFunction = hex(0x3F7A1F, 0x8FCB6B)
    static let syntaxAttribute = hex(0x97590A, 0xFFA14F)
    static let syntaxProperty = hex(0x20609E, 0x82B6F5)

    // Image comparison
    static let checkerLight = hex(0xFFFFFF, 0x2B2A31)
    static let checkerDark = hex(0xECEAF1, 0x222127)
    static let imageDifference = hex(0x2F66D0, 0x86AFF5)

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

    /// A change both sides of a three-way merge made differently, until it is resolved.
    static let conflict = ChangeColors(
        body: hex(0xFFF6E3, 0x30260F),
        bodyCurrent: hex(0xFDEBC2, 0x473713),
        gutter: hex(0xFCEFCF, 0x3A2E12),
        gutterCurrent: hex(0xD9972B, 0xB37E1F),
        inline: hex(0xF8DB9A, 0x6B5219),
        inlineCurrent: hex(0xF3CB75, 0x82631C),
        stroke: hex(0xDFA53F, 0xD09A32),
        marker: hex(0xB87707, 0xECB44C),
        band: dynamic(NSColor(hex: 0xDFA53F, alpha: 0.12), NSColor(hex: 0xD09A32, alpha: 0.14))
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
