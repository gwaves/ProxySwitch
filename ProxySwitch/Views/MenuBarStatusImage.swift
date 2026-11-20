import AppKit

/// Keeps the globe and traffic label in fixed slots in the status button's image.
enum MenuBarStatusImage {
    static let iconOnlyWidth: CGFloat = 30
    static let trafficWidth: CGFloat = 94

    static func make(symbolName: String, color: NSColor?, title: String?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        var icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ProxySwitch")
        if let tint = color ?? (title == nil ? nil : .labelColor) {
            icon = icon?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        icon?.size = size
        guard let title else { return icon ?? NSImage(size: size) }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        let labelHeight = ceil(label.size().height)
        let renderedIcon = icon
        return NSImage(size: NSSize(width: trafficWidth - 12, height: size.height), flipped: false) { _ in
            renderedIcon?.draw(in: NSRect(origin: .zero, size: size))
            label.draw(in: NSRect(x: 23, y: (size.height - labelHeight) / 2, width: 58, height: labelHeight))
            return true
        }
    }
}
