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
        // Both slots have fixed widths. Flexible top and bottom margins keep
        // them centered when the menu bar height changes.
        iconView.frame = NSRect(x: 6, y: bounds.midY - 9, width: 18, height: 18)
        let height = speedLabel.intrinsicContentSize.height
        speedLabel.frame = NSRect(x: 29, y: bounds.midY - height / 2, width: 58, height: height)
        iconView.autoresizingMask = [.minYMargin, .maxYMargin]
        speedLabel.autoresizingMask = [.minYMargin, .maxYMargin]
        addSubview(iconView)
        addSubview(speedLabel)
    }

    required init?(coder: NSCoder) { nil }

    func update(image: NSImage?, title: String, showsTraffic: Bool) {
        if iconView.image !== image { iconView.image = image }
        if showsTraffic && speedLabel.stringValue != title { speedLabel.stringValue = title }
        let hideLabel = !showsTraffic
        if speedLabel.isHidden != hideLabel {
            speedLabel.isHidden = hideLabel
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
