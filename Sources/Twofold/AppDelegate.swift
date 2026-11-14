import AppKit

/// Parsed command-line arguments. Unknown `-NS…`/`-Apple…` pairs from AppKit are skipped.
struct LaunchOptions {
    var paths: [String] = []
    var snapshot: String?
    var appearance: AppearanceChoice?
    var layout: LayoutMode?
    var wrap: Bool?
    var size = CGSize(width: 1360, height: 860)
    var change: Int?
    var fontSize: CGFloat?
    var bench = false
    var scale: CGFloat = 1
    var file: String?

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 0
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--snapshot": o.snapshot = next()
            case "--appearance": o.appearance = next().flatMap(AppearanceChoice.init)
            case "--layout": o.layout = next().flatMap(LayoutMode.init)
            case "--wrap": o.wrap = true
            case "--no-wrap": o.wrap = false
            case "--bench": o.bench = true
            case "--file": o.file = next()
            case "--scale": o.scale = next().flatMap { Double($0) }.map { CGFloat($0) } ?? 1
            case "--change": o.change = next().flatMap { Int($0) }.map { $0 - 1 }
            case "--font-size": o.fontSize = next().flatMap { Double($0) }.map { CGFloat($0) }
            case "--size":
                let parts = (next() ?? "").split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { o.size = CGSize(width: parts[0], height: parts[1]) }
            default:
                if a.hasPrefix("-psn_") {
                } else if a.hasPrefix("-NS") || a.hasPrefix("-Apple") {
                    i += 1
                } else if a.hasPrefix("-") {
                } else {
                    o.paths.append(URL(fileURLWithPath: a).standardizedFileURL.path)
                }
            }
            i += 1
        }
        return o
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let options = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
    private var comparisons: [ComparisonWindowController] = []
    private var welcome: WelcomeWindowController?
    private var launched = false
    private var openedFromEvent = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        if options.snapshot != nil {
            Snapshot.run(options)
            return
        }
        applyAppearance(animated: false)
        if options.paths.count >= 2 {
            openComparison(URL(fileURLWithPath: options.paths[0]), URL(fileURLWithPath: options.paths[1]))
        } else if !openedFromEvent {
            showWelcome(prefill: options.paths.first.map { URL(fileURLWithPath: $0) })
        }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard options.snapshot == nil else { return }
        // AppKit can also deliver command-line paths as open events; those are already handled.
        if !launched && urls.map({ $0.standardizedFileURL.path }) == options.paths { return }
        openedFromEvent = true
        if urls.count >= 2 {
            openComparison(urls[0], urls[1])
        } else if let u = urls.first {
            showWelcome(prefill: u)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Windows

    func openComparison(_ a: URL, _ b: URL, replacing old: ComparisonWindowController? = nil) {
        var isDirA: ObjCBool = false, isDirB: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: a.path, isDirectory: &isDirA), fm.fileExists(atPath: b.path, isDirectory: &isDirB) else {
            let missing = fm.fileExists(atPath: a.path) ? b : a
            alert("Cannot open \(missing.lastPathComponent)", "The file or folder at \(missing.path) does not exist.")
            if comparisons.isEmpty { showWelcome(prefill: nil) }
            return
        }
        guard isDirA.boolValue == isDirB.boolValue else {
            alert("Cannot compare a file with a folder", "Choose two files or two folders.")
            if comparisons.isEmpty { showWelcome(prefill: nil) }
            return
        }
        let wc = ComparisonWindowController(left: a, right: b, kind: isDirA.boolValue ? .folders : .files)
        RecentComparisons.add(left: a, right: b, isFolder: isDirA.boolValue)
        wc.onClose = { [weak self] c in self?.comparisons.removeAll { $0 === c } }
        wc.onDrop = { [weak self, weak wc] urls in
            guard urls.count >= 2 else { return }
            self?.openComparison(urls[0], urls[1], replacing: wc)
        }
        comparisons.append(wc)
        if let old, let frame = old.window?.frame {
            wc.window?.setFrame(frame, display: false)
            old.close()
        } else if let last = comparisons.dropLast().last?.window {
            wc.window?.setFrameTopLeftPoint(last.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            wc.window?.center()
        }
        wc.showWindow(nil)
        wc.start()
        welcome?.close()
        welcome = nil
    }

    func showWelcome(prefill: URL?) {
        if let welcome {
            welcome.showWindow(nil)
            return
        }
        let w = WelcomeWindowController(prefill: prefill)
        w.onCompare = { [weak self] a, b in self?.openComparison(a, b) }
        welcome = w
        w.showWindow(nil)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.runModal()
    }

    // MARK: Appearance

    func applyAppearance(animated: Bool) {
        if animated {
            for w in NSApp.windows where w.isVisible {
                guard let layer = w.contentView?.superview?.layer ?? w.contentView?.layer else { continue }
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.3
                layer.add(fade, forKey: "appearance")
            }
        }
        NSApp.appearance = Preferences.shared.nsAppearance
    }

    // MARK: Actions

    @objc func newComparison(_ sender: Any?) { showWelcome(prefill: nil) }
    @objc func setLayoutBlocks(_ sender: Any?) { Preferences.shared.layout = .blocks }
    @objc func setLayoutFluid(_ sender: Any?) { Preferences.shared.layout = .fluid }
    @objc func toggleWrap(_ sender: Any?) { Preferences.shared.wrapLines.toggle() }
    @objc func toggleInvisibles(_ sender: Any?) { Preferences.shared.showInvisibles.toggle() }
    @objc func biggerText(_ sender: Any?) { Preferences.shared.fontSize += 1 }
    @objc func smallerText(_ sender: Any?) { Preferences.shared.fontSize -= 1 }
    @objc func actualSizeText(_ sender: Any?) { Preferences.shared.fontSize = Preferences.defaultFontSize }

    @objc func setAppearance(_ sender: NSMenuItem) {
        Preferences.shared.appearance = [AppearanceChoice.system, .light, .dark][sender.tag]
        applyAppearance(animated: true)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let p = Preferences.shared
        switch item.action {
        case #selector(setLayoutBlocks(_:)): item.state = p.layout == .blocks ? .on : .off
        case #selector(setLayoutFluid(_:)): item.state = p.layout == .fluid ? .on : .off
        case #selector(toggleWrap(_:)): item.state = p.wrapLines ? .on : .off
        case #selector(toggleInvisibles(_:)): item.state = p.showInvisibles ? .on : .off
        case #selector(setAppearance(_:)):
            item.state = [AppearanceChoice.system, .light, .dark][item.tag] == p.appearance ? .on : .off
        default: break
        }
        return true
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
            return m
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))

        _ = submenu("Twofold", [
            item("About Twofold", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Twofold", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Twofold", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = submenu("File", [
            item("New Comparison…", #selector(newComparison(_:)), "n"),
            item("Open…", #selector(newComparison(_:)), "o"),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Reload", #selector(ComparisonWindowController.reload(_:)), "r"),
            item("Swap Sides", #selector(ComparisonWindowController.swapSides(_:)), "s", [.command, .shift]),
        ])
        _ = submenu("Edit", [
            item("Copy", #selector(DiffCanvasView.copy(_:)), "c"),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
        ])
        let appearance = NSMenu(title: "Appearance")
        appearance.addItem(item("System", #selector(setAppearance(_:)), tag: 0))
        appearance.addItem(item("Light", #selector(setAppearance(_:)), tag: 1))
        appearance.addItem(item("Dark", #selector(setAppearance(_:)), tag: 2))
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance
        _ = submenu("View", [
            item("Blocks", #selector(setLayoutBlocks(_:)), "1"),
            item("Fluid", #selector(setLayoutFluid(_:)), "2"),
            .separator(),
            item("Wrap Lines", #selector(toggleWrap(_:)), "l", [.command, .option]),
            item("Show Invisibles", #selector(toggleInvisibles(_:)), "i", [.command, .option]),
            item("Expand Unchanged Lines", #selector(ComparisonWindowController.toggleExpandAll(_:)), "e", [.command, .option]),
            .separator(),
            item("Bigger", #selector(biggerText(_:)), "+"),
            item("Smaller", #selector(smallerText(_:)), "-"),
            item("Actual Size", #selector(actualSizeText(_:)), "0"),
            .separator(),
            appearanceItem,
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        _ = submenu("Navigate", [
            item("Next Change", #selector(ComparisonWindowController.nextChange(_:)), down),
            item("Previous Change", #selector(ComparisonWindowController.previousChange(_:)), up),
            .separator(),
            item("Next File", #selector(ComparisonWindowController.nextFile(_:)), down, [.command, .option]),
            item("Previous File", #selector(ComparisonWindowController.previousFile(_:)), up, [.command, .option]),
        ])
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window
        return main
    }
}
