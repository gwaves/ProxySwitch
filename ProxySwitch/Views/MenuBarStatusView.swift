import AppKit

/// Separate, fixed frames keep both the globe and neighboring status items
/// stationary as the traffic value changes. The enclosing status button handles
/// all mouse events, including right-clicks.
final class MenuBarStatusView: NSView {
    static let iconOnlyWidth: CGFloat = 30
    static let trafficWidth: CGFloat = 94

    private let iconView = NSImageView()
    private let speedLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        speedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        speedLabel.alignment = .right
        speedLabel.lineBreakMode = .byTruncatingTail
        iconView.setAccessibilityElement(false)
        speedLabel.setAccessibilityElement(false)
        addSubview(iconView)
        addSubview(speedLabel)
    }

    required init?(coder: NSCoder) { nil }

    func update(image: NSImage?, title: String, showsTraffic: Bool) {
        if iconView.image !== image { iconView.image = image }
        if speedLabel.stringValue != title { speedLabel.stringValue = title }
        speedLabel.isHidden = !showsTraffic
        needsLayout = true
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 6, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let labelHeight = speedLabel.intrinsicContentSize.height
        speedLabel.frame = NSRect(x: 29, y: (bounds.height - labelHeight) / 2,
                                 width: 58, height: labelHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
