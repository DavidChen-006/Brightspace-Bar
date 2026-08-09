import AppKit

@MainActor
enum RateLimitStatusIconRenderer {
    private static let outputSize = NSSize(width: 18, height: 18)
    private static var cache: [CacheKey: NSImage] = [:]

    static func makeIcon(restPercent: Double?, graphQLPercent: Double?) -> NSImage {
        let key = CacheKey(rest: Self.bucket(restPercent), graphQL: Self.bucket(graphQLPercent))
        if let cached = self.cache[key] {
            return cached
        }

        let image = NSImage(size: Self.outputSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: Self.outputSize)).fill()

        let baseFill = NSColor.labelColor
        Self.drawRestRing(percent: restPercent, baseFill: baseFill)
        Self.drawGraphQLDot(percent: graphQLPercent, baseFill: baseFill)

        image.isTemplate = true
        self.cache[key] = image
        return image
    }

    private static func drawRestRing(percent: Double?, baseFill: NSColor) {
        let center = CGPoint(x: Self.outputSize.width / 2, y: Self.outputSize.height / 2)
        let radius: CGFloat = 6.5
        let lineWidth: CGFloat = 2.1
        let trackRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )

        let track = NSBezierPath(ovalIn: trackRect)
        track.lineWidth = lineWidth
        baseFill.withAlphaComponent(0.34).setStroke()
        track.stroke()

        guard let percent else { return }

        let clamped = max(0, min(percent / 100, 1))
        guard clamped > 0 else { return }

        let startAngle: CGFloat = 90
        let endAngle = startAngle - (360 * CGFloat(clamped))
        let progress = NSBezierPath()
        progress.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        progress.lineWidth = lineWidth
        progress.lineCapStyle = .round
        baseFill.setStroke()
        progress.stroke()
    }

    private static func drawGraphQLDot(percent: Double?, baseFill: NSColor) {
        let dotSize: CGFloat = 4.4
        let dotRect = CGRect(
            x: (Self.outputSize.width - dotSize) / 2,
            y: (Self.outputSize.height - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        let dot = NSBezierPath(ovalIn: dotRect)
        let alpha = percent.map { max(0.26, min(CGFloat($0 / 100), 1)) } ?? 0.28
        baseFill.withAlphaComponent(alpha).setFill()
        dot.fill()
    }

    private static func bucket(_ percent: Double?) -> Int {
        guard let percent else { return -1 }

        return Int(max(0, min(100, percent)).rounded())
    }

    private struct CacheKey: Hashable {
        let rest: Int
        let graphQL: Int
    }
}
