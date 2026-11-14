import Foundation

/// Myers' O(ND) difference algorithm, linear-space variant (bisection on the middle snake).
public enum Myers {
    /// Marks which elements of `a` and `b` belong to a longest common subsequence.
    ///
    /// If `timeLimit` seconds pass, the remaining unsolved regions are reported as fully changed,
    /// which keeps pathological inputs from hanging the caller.
    public static func matches(_ a: [Int32], _ b: [Int32], timeLimit: Double = 2.0) -> (left: [Bool], right: [Bool]) {
        var am = [Bool](repeating: false, count: a.count)
        var bm = [Bool](repeating: false, count: b.count)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(max(0, timeLimit) * 1e9)
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                am.withUnsafeMutableBufferPointer { amp in
                    bm.withUnsafeMutableBufferPointer { bmp in
                        var solver = Solver(a: ap, b: bp, am: amp, bm: bmp, deadline: deadline)
                        solver.solve(0, ap.count, 0, bp.count)
                    }
                }
            }
        }
        return (am, bm)
    }
}

private struct Solver {
    let a: UnsafeBufferPointer<Int32>
    let b: UnsafeBufferPointer<Int32>
    let am: UnsafeMutableBufferPointer<Bool>
    let bm: UnsafeMutableBufferPointer<Bool>
    let deadline: UInt64
    var timedOut = false

    init(a: UnsafeBufferPointer<Int32>, b: UnsafeBufferPointer<Int32>,
         am: UnsafeMutableBufferPointer<Bool>, bm: UnsafeMutableBufferPointer<Bool>, deadline: UInt64) {
        self.a = a; self.b = b; self.am = am; self.bm = bm; self.deadline = deadline
    }

    mutating func solve(_ aLo0: Int, _ aHi0: Int, _ bLo0: Int, _ bHi0: Int) {
        var aLo = aLo0, aHi = aHi0, bLo = bLo0, bHi = bHi0
        while aLo < aHi && bLo < bHi && a[aLo] == b[bLo] {
            am[aLo] = true; bm[bLo] = true; aLo += 1; bLo += 1
        }
        while aLo < aHi && bLo < bHi && a[aHi - 1] == b[bHi - 1] {
            aHi -= 1; bHi -= 1; am[aHi] = true; bm[bHi] = true
        }
        if aLo == aHi || bLo == bHi || timedOut { return }
        guard let (x, y) = bisect(aLo, aHi, bLo, bHi) else { return }
        // Guard against a split that would not shrink the problem.
        if (x == aLo && y == bLo) || (x == aHi && y == bHi) { return }
        solve(aLo, x, bLo, y)
        solve(x, aHi, y, bHi)
    }

    /// Finds the middle snake and returns the split point, or nil if there is no common element
    /// (or time ran out).
    mutating func bisect(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) -> (Int, Int)? {
        let n = aHi - aLo, m = bHi - bLo
        let maxD = (n + m + 1) / 2
        let vOffset = maxD
        let vLength = 2 * maxD + 2
        let v1 = UnsafeMutablePointer<Int>.allocate(capacity: vLength)
        let v2 = UnsafeMutablePointer<Int>.allocate(capacity: vLength)
        defer { v1.deallocate(); v2.deallocate() }
        v1.initialize(repeating: -1, count: vLength)
        v2.initialize(repeating: -1, count: vLength)
        v1[vOffset + 1] = 0
        v2[vOffset + 1] = 0
        let delta = n - m
        let front = (delta & 1) != 0
        var k1start = 0, k1end = 0, k2start = 0, k2end = 0
        let ap = a.baseAddress!, bp = b.baseAddress!

        for d in 0..<maxD {
            if d & 31 == 0 && DispatchTime.now().uptimeNanoseconds > deadline {
                timedOut = true
                return nil
            }
            var k1 = -d + k1start
            while k1 <= d - k1end {
                let k1Offset = vOffset + k1
                var x1: Int
                if k1 == -d || (k1 != d && v1[k1Offset - 1] < v1[k1Offset + 1]) {
                    x1 = v1[k1Offset + 1]
                } else {
                    x1 = v1[k1Offset - 1] + 1
                }
                var y1 = x1 - k1
                while x1 < n && y1 < m && ap[aLo + x1] == bp[bLo + y1] { x1 += 1; y1 += 1 }
                v1[k1Offset] = x1
                if x1 > n {
                    k1end += 2
                } else if y1 > m {
                    k1start += 2
                } else if front {
                    let k2Offset = vOffset + delta - k1
                    if k2Offset >= 0 && k2Offset < vLength && v2[k2Offset] != -1 {
                        let x2 = n - v2[k2Offset]
                        if x1 >= x2 { return (aLo + x1, bLo + y1) }
                    }
                }
                k1 += 2
            }
            var k2 = -d + k2start
            while k2 <= d - k2end {
                let k2Offset = vOffset + k2
                var x2: Int
                if k2 == -d || (k2 != d && v2[k2Offset - 1] < v2[k2Offset + 1]) {
                    x2 = v2[k2Offset + 1]
                } else {
                    x2 = v2[k2Offset - 1] + 1
                }
                var y2 = x2 - k2
                while x2 < n && y2 < m && ap[aHi - 1 - x2] == bp[bHi - 1 - y2] { x2 += 1; y2 += 1 }
                v2[k2Offset] = x2
                if x2 > n {
                    k2end += 2
                } else if y2 > m {
                    k2start += 2
                } else if !front {
                    let k1Offset = vOffset + delta - k2
                    if k1Offset >= 0 && k1Offset < vLength && v1[k1Offset] != -1 {
                        let x1 = v1[k1Offset]
                        let y1 = vOffset + x1 - k1Offset
                        if x1 >= n - x2 { return (aLo + x1, bLo + y1) }
                    }
                }
                k2 += 2
            }
        }
        return nil
    }
}
