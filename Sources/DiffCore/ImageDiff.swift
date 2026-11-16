import Foundation

/// Decoded pixels: 8-bit RGBA with premultiplied alpha, top row first.
public struct PixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let data: Data

    public init(width: Int, height: Int, bytesPerRow: Int, data: Data) {
        precondition(width >= 0 && height >= 0 && bytesPerRow >= width * 4 && data.count >= bytesPerRow * height)
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.data = data
    }

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.init(width: width, height: height, bytesPerRow: width * 4, data: Data(rgba))
    }
}

/// A rectangle in pixel coordinates, origin at the top left.
public struct PixelRect: Sendable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Pixel-by-pixel comparison of two images aligned at their top-left corners.
///
/// The canvas is the union of both sizes. Where only one image has pixels, the other counts as
/// transparent, so a size difference shows up as differing pixels unless that area is transparent too.
public struct ImageDiff: Sendable {
    /// Differing pixels closer than this many pixels end up in the same region.
    public static let cellSize = 16

    public let width: Int
    public let height: Int
    public let differingPixels: Int
    /// Bounding boxes of clusters of differing pixels, in reading order.
    public let regions: [PixelRect]
    /// One byte per canvas pixel: 0 where the images agree, otherwise the largest channel difference.
    public let mask: Data

    public var totalPixels: Int { width * height }
    public var isIdentical: Bool { differingPixels == 0 }
    public var fraction: Double { totalPixels == 0 ? 0 : Double(differingPixels) / Double(totalPixels) }

    /// - Parameter tolerance: channel differences up to this value are ignored.
    public init(left: PixelBuffer?, right: PixelBuffer?, tolerance: Int = 0) {
        let lw = left?.width ?? 0, lh = left?.height ?? 0
        let rw = right?.width ?? 0, rh = right?.height ?? 0
        let w = max(lw, rw), h = max(lh, rh)
        width = w
        height = h
        guard w > 0, h > 0 else {
            differingPixels = 0
            regions = []
            mask = Data()
            return
        }

        let cell = Self.cellSize
        let gw = (w + cell - 1) / cell, gh = (h + cell - 1) / cell
        // Tight bounds of the differing pixels inside each grid cell; minX == Int32.max means none.
        var minX = [Int32](repeating: .max, count: gw * gh)
        var maxX = [Int32](repeating: -1, count: gw * gh)
        var minY = [Int32](repeating: .max, count: gw * gh)
        var maxY = [Int32](repeating: -1, count: gw * gh)
        var count = 0
        var maskData = Data(count: w * h)
        let lbpr = left?.bytesPerRow ?? 0, rbpr = right?.bytesPerRow ?? 0

        maskData.withUnsafeMutableBytes { (m: UnsafeMutableRawBufferPointer) in
            let out = m.bindMemory(to: UInt8.self).baseAddress!
            Self.withBytes(left) { lp in
                Self.withBytes(right) { rp in
                    for y in 0..<h {
                        let lrow = y < lh ? lp.map { $0 + y * lbpr } : nil
                        let rrow = y < rh ? rp.map { $0 + y * rbpr } : nil
                        let row = out + y * w
                        let gy = (y / cell) * gw
                        func mark(_ x: Int, _ d: Int) {
                            row[x] = UInt8(d)
                            count += 1
                            let c = gy + x / cell
                            if Int32(x) < minX[c] { minX[c] = Int32(x) }
                            if Int32(x) > maxX[c] { maxX[c] = Int32(x) }
                            if Int32(y) < minY[c] { minY[c] = Int32(y) }
                            maxY[c] = Int32(y)
                        }
                        var overlap = 0
                        if let lrow, let rrow {
                            overlap = min(lw, rw)
                            if memcmp(lrow, rrow, overlap * 4) != 0 {
                                for x in 0..<overlap {
                                    let a = lrow + x * 4, b = rrow + x * 4
                                    let d = max(max(abs(Int(a[0]) - Int(b[0])), abs(Int(a[1]) - Int(b[1]))),
                                                max(abs(Int(a[2]) - Int(b[2])), abs(Int(a[3]) - Int(b[3]))))
                                    if d > tolerance { mark(x, d) }
                                }
                            }
                        }
                        // Pixels present on one side only are compared against transparent.
                        for (ptr, n) in [(lrow, lw), (rrow, rw)] {
                            guard let ptr, n > overlap else { continue }
                            for x in overlap..<n {
                                let a = ptr + x * 4
                                let d = Int(max(max(a[0], a[1]), max(a[2], a[3])))
                                if d > tolerance { mark(x, d) }
                            }
                        }
                    }
                }
            }
        }

        differingPixels = count
        mask = maskData
        regions = count == 0 ? [] : Self.regions(gw: gw, gh: gh, minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    private static func withBytes<R>(_ buffer: PixelBuffer?, _ body: (UnsafePointer<UInt8>?) -> R) -> R {
        guard let buffer, buffer.data.count > 0 else { return body(nil) }
        return buffer.data.withUnsafeBytes { body($0.bindMemory(to: UInt8.self).baseAddress) }
    }

    /// Joins touching grid cells (including diagonals) into regions and returns their tight bounds.
    private static func regions(gw: Int, gh: Int, minX: [Int32], maxX: [Int32], minY: [Int32], maxY: [Int32]) -> [PixelRect] {
        var visited = [Bool](repeating: false, count: gw * gh)
        var result: [PixelRect] = []
        var stack: [Int] = []
        for start in 0..<(gw * gh) where !visited[start] && maxX[start] >= 0 {
            var x0 = Int32.max, x1 = Int32(-1), y0 = Int32.max, y1 = Int32(-1)
            visited[start] = true
            stack.append(start)
            while let c = stack.popLast() {
                x0 = min(x0, minX[c]); x1 = max(x1, maxX[c])
                y0 = min(y0, minY[c]); y1 = max(y1, maxY[c])
                let cx = c % gw, cy = c / gw
                for ny in max(0, cy - 1)...min(gh - 1, cy + 1) {
                    for nx in max(0, cx - 1)...min(gw - 1, cx + 1) {
                        let n = ny * gw + nx
                        if !visited[n] && maxX[n] >= 0 {
                            visited[n] = true
                            stack.append(n)
                        }
                    }
                }
            }
            result.append(PixelRect(x: Int(x0), y: Int(y0), width: Int(x1 - x0) + 1, height: Int(y1 - y0) + 1))
        }
        return result
    }
}
