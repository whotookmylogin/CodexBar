import AppKit

enum IconRenderer {
    static func makeIcon(
        primaryRemaining: Double?,
        weeklyRemaining: Double?,
        stale: Bool,
        badge: String? = nil) -> NSImage
    {
        let size = NSSize(width: badge == nil ? 20 : 28, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let trackColor = NSColor.labelColor.withAlphaComponent(stale ? 0.35 : 0.6)
        let fillColor = NSColor.labelColor.withAlphaComponent(stale ? 0.55 : 1.0)

        func drawBar(x: CGFloat, y: CGFloat, remaining: Double?, height: CGFloat, width: CGFloat) {
            let radius = height / 2
            let trackRect = CGRect(x: x, y: y, width: width, height: height)
            let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)
            trackColor.setStroke()
            trackPath.lineWidth = 1
            trackPath.stroke()

            guard let remaining else { return }
            let clamped = max(0, min(remaining / 100, 1))
            let fillRect = CGRect(x: x, y: y, width: width * clamped, height: height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
            fillColor.setFill()
            fillPath.fill()
        }

        let barX: CGFloat = badge == nil ? 3 : 10
        let barWidth: CGFloat = 14
        drawBar(x: barX, y: 9.5, remaining: primaryRemaining, height: 3.2, width: barWidth)
        drawBar(x: barX, y: 4.0, remaining: weeklyRemaining, height: 2.0, width: barWidth)

        if let badge, !badge.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(stale ? 0.55 : 0.95),
            ]
            let text = badge as NSString
            text.draw(at: NSPoint(x: 1, y: 4), withAttributes: attrs)
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
