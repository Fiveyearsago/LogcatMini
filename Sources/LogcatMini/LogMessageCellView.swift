import AppKit

/// All messages share the table's horizontal position; no per-row scrolling state.
final class LogMessageCellView: NSTableCellView {
    static let trailingInset: CGFloat = 16
    private var textSize = NSSize.zero
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "")
        label.maximumNumberOfLines = 1; label.lineBreakMode = .byClipping
        label.allowsExpansionToolTips = false
        addSubview(label); textField = label
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setMessage(_ value: NSAttributedString) {
        if textField?.attributedStringValue != value {
            textField?.attributedStringValue = value
            textSize = value.size()
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        textField?.frame = NSRect(x: 0, y: floor((bounds.height - textSize.height) / 2),
                                 width: max(0, bounds.width - Self.trailingInset), height: ceil(textSize.height))
    }
}
