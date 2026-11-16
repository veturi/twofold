import AppKit

/// The find bar above the panes: a search field, the match count, previous and next, and Done.
@MainActor
final class FindBarView: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 34

    let field = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let stepper = NSSegmentedControl()
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    /// Called with the text as it is typed.
    var onQuery: ((String) -> Void)?
    /// Called with true for the next match and false for the previous one.
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Find in both files"
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.delegate = self
        field.target = self
        field.action = #selector(fieldChanged)
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel("Find")

        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = Theme.secondaryText

        stepper.segmentCount = 2
        stepper.trackingMode = .momentary
        stepper.controlSize = .small
        for (i, (symbol, tip)) in [("chevron.left", "Previous Match (⇧⌘G)"), ("chevron.right", "Next Match (⌘G)")].enumerated() {
            stepper.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: tip), forSegment: i)
            stepper.setToolTip(tip, forSegment: i)
            stepper.setWidth(26, forSegment: i)
        }
        stepper.target = self
        stepper.action = #selector(stepped)

        doneButton.controlSize = .small
        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(close)

        let stack = NSStackView(views: [field, stepper, countLabel, NSView(), doneButton])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 280),
        ])
        setCount(current: nil, total: 0, overflow: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// Shows "3 of 17", or that nothing matches the text in the field.
    func setCount(current: Int?, total: Int, overflow: Bool) {
        let empty = field.stringValue.isEmpty
        stepper.isEnabled = total > 0
        countLabel.textColor = total == 0 && !empty ? Theme.removed.marker : Theme.secondaryText
        if empty {
            countLabel.stringValue = ""
        } else if total == 0 {
            countLabel.stringValue = "No matches"
        } else {
            let count = total.formatted() + (overflow ? "+" : "")
            countLabel.stringValue = current.map { "\(($0 + 1).formatted()) of \(count)" } ?? "\(count) match\(total == 1 ? "" : "es")"
        }
    }

    @objc private func fieldChanged() { onQuery?(field.stringValue) }
    @objc private func stepped() { onStep?(stepper.selectedSegment == 1) }
    @objc private func close() { onClose?() }

    func controlTextDidChange(_ obj: Notification) { onQuery?(field.stringValue) }

    /// Return goes to the next match, Shift-Return to the previous one, and Escape closes the bar.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onStep?(NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.separator.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
