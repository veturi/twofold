import CoreGraphics
import DiffCore
import Foundation
import ImageIO

/// Two decoded images and their pixel comparison, ready to draw.
struct ImageComparison: @unchecked Sendable {
    /// Upright sRGB images at the size they were compared at.
    var left: CGImage?
    var right: CGImage?
    /// Greyscale image of the differing pixels, used as a clipping mask.
    var mask: CGImage?
    var diff: ImageDiff
    /// Pixel sizes of the files themselves, which are larger than the images when `reduced`.
    var leftSize: CGSize?
    var rightSize: CGSize?
    /// True when a very large image was scaled down before comparing.
    var reduced: Bool

    /// Images above this many pixels are scaled down to it before comparing.
    static let maxPixels = 64_000_000

    /// Decodes whichever files are given. Returns nil unless every given file is an image ImageIO can read.
    static func load(_ l: URL?, _ r: URL?) -> ImageComparison? {
        guard l != nil || r != nil else { return nil }
        var sides: [Decoded?] = [nil, nil]
        for (i, url) in [l, r].enumerated() {
            guard let url else { continue }
            guard let d = decode(url) else { return nil }
            sides[i] = d
        }
        // Both sides must use the same scale for their pixels to line up.
        if let a = sides[0], let b = sides[1], a.scale != b.scale, let l, let r {
            let s = min(a.scale, b.scale)
            sides = [decode(l, scale: s), decode(r, scale: s)]
        }
        let diff = ImageDiff(left: sides[0]?.buffer, right: sides[1]?.buffer)
        return ImageComparison(
            left: sides[0]?.image, right: sides[1]?.image, mask: maskImage(diff), diff: diff,
            leftSize: sides[0]?.fullSize, rightSize: sides[1]?.fullSize,
            reduced: sides.contains { ($0?.scale ?? 1) < 1 })
    }

    private struct Decoded {
        var image: CGImage
        var buffer: PixelBuffer
        var fullSize: CGSize
        var scale: Double
    }

    /// Draws the first frame of an image file upright into an sRGB RGBA buffer.
    private static func decode(_ url: URL, scale forced: Double? = nil) -> Decoded? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let raw = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
        let turned = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let fullW = turned ? raw.height : raw.width, fullH = turned ? raw.width : raw.height
        guard fullW > 0, fullH > 0 else { return nil }
        let scale = forced ?? min(1, (Double(maxPixels) / (Double(fullW) * Double(fullH))).squareRoot())
        let w = scale < 1 ? max(1, Int(Double(fullW) * scale)) : fullW
        let h = scale < 1 ? max(1, Int(Double(fullH) * scale)) : fullH
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        var data = Data(count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = scale < 1 ? .high : .none
            let fw = CGFloat(w), fh = CGFloat(h)
            // Core Graphics coordinates: origin bottom left. Each case maps the stored image to upright.
            switch orientation {
            case .up: break
            case .upMirrored: ctx.translateBy(x: fw, y: 0); ctx.scaleBy(x: -1, y: 1)
            case .down: ctx.translateBy(x: fw, y: fh); ctx.rotate(by: .pi)
            case .downMirrored: ctx.translateBy(x: 0, y: fh); ctx.scaleBy(x: 1, y: -1)
            case .leftMirrored: ctx.translateBy(x: fw, y: fh); ctx.scaleBy(x: 1, y: -1); ctx.rotate(by: .pi / 2)
            case .right: ctx.translateBy(x: 0, y: fh); ctx.rotate(by: -.pi / 2)
            case .rightMirrored: ctx.scaleBy(x: -1, y: 1); ctx.rotate(by: .pi / 2)
            case .left: ctx.translateBy(x: fw, y: 0); ctx.rotate(by: .pi / 2)
            }
            ctx.draw(raw, in: CGRect(x: 0, y: 0, width: turned ? fh : fw, height: turned ? fw : fh))
            return true
        }
        guard drawn,
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return Decoded(image: image, buffer: PixelBuffer(width: w, height: h, bytesPerRow: w * 4, data: data),
                       fullSize: CGSize(width: fullW, height: fullH), scale: scale)
    }

    /// Turns difference strengths into coverage. Even the faintest difference stays clearly visible.
    private static func maskImage(_ diff: ImageDiff) -> CGImage? {
        guard !diff.isIdentical else { return nil }
        var table = [UInt8](repeating: 0, count: 256)
        for v in 1..<256 { table[v] = UInt8(120 + v * 135 / 255) }
        var data = diff.mask
        data.withUnsafeMutableBytes { bytes in
            for i in bytes.indices { bytes[i] = table[Int(bytes[i])] }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: diff.width, height: diff.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: diff.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
