import AppKit

enum LayoutMode: String {
    case fluid, blocks
}

enum AppearanceChoice: String {
    case system, light, dark
}

/// App-wide view settings, persisted in user defaults. Snapshot runs override them in memory only.
@MainActor
final class Preferences {
    static let shared = Preferences()
    static let didChange = Notification.Name("TwofoldPreferencesDidChange")

    private let defaults = UserDefaults.standard
    var overrides: [String: Any] = [:]

    private func value(_ key: String) -> Any? {
        overrides[key] ?? defaults.object(forKey: key)
    }

    private func set(_ value: Any, _ key: String) {
        if overrides[key] != nil { overrides[key] = value } else { defaults.set(value, forKey: key) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    static let defaultFontSize: CGFloat = 12

    var fontSize: CGFloat {
        get { (value("fontSize") as? Double).map { CGFloat($0) } ?? Self.defaultFontSize }
        set { set(Double(min(max(newValue, 8), 32)), "fontSize") }
    }

    var layout: LayoutMode {
        get { (value("layout") as? String).flatMap(LayoutMode.init) ?? .fluid }
        set { set(newValue.rawValue, "layout") }
    }

    var wrapLines: Bool {
        get { value("wrapLines") as? Bool ?? true }
        set { set(newValue, "wrapLines") }
    }

    var showInvisibles: Bool {
        get { value("showInvisibles") as? Bool ?? true }
        set { set(newValue, "showInvisibles") }
    }

    var appearance: AppearanceChoice {
        get { (value("appearance") as? String).flatMap(AppearanceChoice.init) ?? .system }
        set { set(newValue.rawValue, "appearance") }
    }

    var nsAppearance: NSAppearance? {
        switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
