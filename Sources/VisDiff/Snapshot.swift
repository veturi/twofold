import AppKit

/// Renders a comparison window offscreen to a PNG and exits. Used to verify the UI without a screen.
///
///     VisDiff --snapshot out.png [--appearance dark] [--layout blocks] [--size 1360x860] [--change 3] A B
@MainActor
enum Snapshot {
    static func run(_ o: LaunchOptions) {
        guard let out = o.snapshot else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        if o.paths.count < 2 {
            let welcome = WelcomeWindowController(prefill: o.paths.first.map { URL(fileURLWithPath: $0) })
            if o.appearance == .dark { welcome.window?.appearance = NSAppearance(named: .darkAqua) }
            welcome.window?.layoutIfNeeded()
            capture(welcome.window!, to: out, scale: o.scale)
            exit(0)
        }
        let p = Preferences.shared
        if let l = o.layout { p.overrides["layout"] = l.rawValue }
        if let w = o.wrap { p.overrides["wrapLines"] = w }
        if let f = o.fontSize { p.overrides["fontSize"] = Double(f) }
        p.overrides["showInvisibles"] = p.showInvisibles

        let a = URL(fileURLWithPath: o.paths[0]), b = URL(fileURLWithPath: o.paths[1])
        let isDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let wc = ComparisonWindowController(left: a, right: b, kind: isDir ? .folders : .files)
        wc.initialSelection = o.file
        guard let window = wc.window else { exit(1) }
        switch o.appearance {
        case .dark?: window.appearance = NSAppearance(named: .darkAqua)
        case .light?: window.appearance = NSAppearance(named: .aqua)
        default: break
        }
        window.setContentSize(o.size)
        window.layoutIfNeeded()
        wc.start()

        Task {
            let started = Date()
            var settledAt: Date?
            while true {
                try? await Task.sleep(for: .milliseconds(50))
                if wc.isBusy && Date().timeIntervalSince(started) < 15 { settledAt = nil; continue }
                if settledAt == nil { settledAt = Date() }
                if Date().timeIntervalSince(settledAt!) > 0.25 { break }
            }
            window.layoutIfNeeded()
            print(String(format: "ready after %.0f ms", Date().timeIntervalSince(started) * 1000 - 250))
            if o.bench { benchmark(wc.diffVC.canvas) }
            if let c = o.change { wc.diffVC.canvas.goToChange(c, animated: false) }
            capture(window, to: out, scale: o.scale)
            exit(0)
        }
    }

    /// Renders the canvas at many scroll positions, as a scroll gesture would, and reports frame times.
    static func benchmark(_ canvas: DiffCanvasView) {
        let b = canvas.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = b.size
        var times: [Double] = []
        var t: CGFloat = 0
        for _ in 0..<600 {
            t += 37
            canvas.setScroll(t)
            let start = DispatchTime.now().uptimeNanoseconds
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        times.sort()
        let avg = times.reduce(0, +) / Double(times.count)
        print(String(format: "frames: %d  avg %.2f ms  p95 %.2f ms  max %.2f ms  (120 Hz budget 8.3 ms)",
                     times.count, avg, times[times.count * 95 / 100], times.last ?? 0))
    }

    static func capture(_ window: NSWindow, to path: String, scale: CGFloat = 1) {
        guard let view = window.contentView?.superview ?? window.contentView else { exit(1) }
        view.layoutSubtreeIfNeeded()
        let b = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * scale), pixelsHigh: Int(b.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
        rep.size = b.size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("Wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
