import AppKit

/// Renders a comparison window offscreen to a PNG and exits. Used to verify the UI without a screen.
///
///     Twofold --snapshot out.png [--appearance dark] [--layout blocks] [--size 1360x860] [--change 3] A B
///
/// For two images, `--image-mode side-by-side|overlay|difference` and `--zoom 2` pick the view.
/// `--copy left|right` copies the current change to that side first. `--caret left:12:4 --type "text\n"`
/// places the caret and types. `--undo` then undoes the last step and `--save` writes the edited files.
@MainActor
enum Snapshot {
    static func run(_ o: LaunchOptions) {
        guard let out = o.snapshot else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        if let setup = o.gitSetup {
            runGitSetup(setup, o, to: out)
            return
        }
        if o.paths.count < 2 {
            let welcome = WelcomeWindowController(prefill: o.paths.first.map { URL(fileURLWithPath: $0) })
            if o.appearance == .dark { welcome.window?.appearance = NSAppearance(named: .darkAqua) }
            welcome.window?.layoutIfNeeded()
            capture(welcome.window!, to: out, scale: o.scale)
            exit(0)
        }
        let p = Preferences.shared
        if let l = o.layout { p.overrides["layout"] = l.rawValue }
        if let m = o.imageMode { p.overrides["imageMode"] = m.rawValue }
        if let w = o.wrap { p.overrides["wrapLines"] = w }
        if let s = o.syntax { p.overrides["syntaxHighlighting"] = s }
        p.overrides["ignoreWhitespace"] = o.ignoreWhitespace
        if let f = o.fontSize { p.overrides["fontSize"] = Double(f) }
        p.overrides["showInvisibles"] = p.showInvisibles

        let a = URL(fileURLWithPath: o.paths[0]), b = URL(fileURLWithPath: o.paths[1])
        if let output = o.output {
            runMerge(o, local: a, remote: b, output: URL(fileURLWithPath: output), to: out)
            return
        }
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
            if let z = o.zoom { wc.diffVC.imageView.setZoom(z) }
            if let query = o.find {
                let began = Date()
                wc.diffVC.find(query)
                print(String(format: "find took %.1f ms", Date().timeIntervalSince(began) * 1000))
                for _ in 0..<o.findNext { wc.diffVC.findStep(forward: true) }
                let c = wc.diffVC.canvas
                print("matches: \(c.findMatches.count)  current: \(c.findIndex.map { String($0 + 1) } ?? "none")")
            }
            let canvas = wc.diffVC.canvas
            @MainActor func settle() async {
                while wc.isBusy || canvas.hasPendingOps { try? await Task.sleep(for: .milliseconds(20)) }
            }
            if let side = o.copy {
                wc.diffVC.copyChange(to: side)
                await settle()
            }
            if let (side, line, column) = o.caret {
                window.makeFirstResponder(canvas)
                canvas.setCaret(side, line: line, column: column)
                if let text = o.typed { canvas.type(text) }
                await settle()
            }
            if o.copy != nil || o.typed != nil {
                if o.undo {
                    wc.diffVC.undo.undo()
                    await settle()
                }
                if o.save {
                    print(wc.diffVC.save() ? "saved" : "save failed")
                    await settle()
                }
                window.layoutIfNeeded()
            }
            capture(window, to: out, scale: o.scale)
            exit(0)
        }
    }

    /// A three-way merge: `--change N` picks a change, `--use left|right|both` resolves it (or several
    /// at once: `--use 3:left,5:both`),
    /// `--caret left:LINE:COLUMN --type "text"` types into the result at that line and column,
    /// `--undo` undoes the last step and `--save` writes the result.
    private static func runMerge(_ o: LaunchOptions, local: URL, remote: URL, output: URL, to out: String) {
        let wc = MergeWindowController(base: o.base.map { URL(fileURLWithPath: $0) }, local: local, remote: remote, output: output)
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
            while wc.isBusy && Date().timeIntervalSince(started) < 15 { try? await Task.sleep(for: .milliseconds(20)) }
            try? await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
            let vc = wc.mergeVC
            if let c = o.change { vc.canvas.goToChange(c, animated: false) }
            // "left", or several as "3:left,5:both" with one-based change numbers.
            for item in (o.use ?? "").split(separator: ",") {
                let parts = item.split(separator: ":")
                let side = parts.last.map(String.init) ?? ""
                let change = parts.count == 2 ? Int(parts[0]).map { $0 - 1 } : nil
                vc.use(side == "left" ? .local : (side == "right" ? .remote : .both), change: change)
            }
            if o.use?.contains(":") == true, let c = o.change { vc.canvas.goToChange(c, animated: false) }
            if let (_, line, column) = o.caret, let text = o.typed {
                let view = vc.result.textView
                let string = view.string as NSString
                var at = 0
                for _ in 0..<line where at < string.length { at = NSMaxRange(string.lineRange(for: NSRange(location: at, length: 0))) }
                window.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: min(at + column, string.length), length: 0))
                view.insertText(text, replacementRange: view.selectedRange())
            }
            if o.undo { vc.undo.undo() }
            if o.save { print(vc.save(confirmConflicts: false) ? "saved" : "save failed") }
            print("changes: \(vc.canvas.changeCount)  unresolved: \(vc.unresolvedCount)  unsaved: \(vc.hasUnsavedChanges)")
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
            capture(window, to: out, scale: o.scale)
            exit(0)
        }
    }

    /// The Git Integration window. `--git-setup diff=on,merge=off` flips those switches first, and
    /// `--git-setup show` only shows the current state. Set `GIT_CONFIG_GLOBAL` to try it on a scratch file.
    private static func runGitSetup(_ setup: String, _ o: LaunchOptions, to out: String) {
        let wc = GitSetupWindowController()
        switch o.appearance {
        case .dark?: wc.window?.appearance = NSAppearance(named: .darkAqua)
        case .light?: wc.window?.appearance = NSAppearance(named: .aqua)
        default: break
        }
        Task {
            await wc.refresh()
            for item in setup.split(separator: ",") {
                let parts = item.split(separator: "=")
                guard parts.count == 2, parts[0] == "diff" || parts[0] == "merge" else { continue }
                await wc.set(parts[0] == "diff" ? .diff : .merge, on: parts[1] == "on")
            }
            print("diff: \(wc.states[.diff].map { "\($0)" } ?? "unavailable")  merge: \(wc.states[.merge].map { "\($0)" } ?? "unavailable")")
            wc.window?.layoutIfNeeded()
            capture(wc.window!, to: out, scale: o.scale)
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
