import AppKit
import SwiftUI

/// The menu bar: a template gyoza glyph and, when the setting asks for it
/// and something is loaded, one mono number in a slot wide enough for the
/// largest value, so the bar never reflows.
struct StatusItemLabel: View {
    let modelBytes: UInt64
    let modelCount: Int
    let content: StatusItemContent

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(nsImage: Self.glyph)
            if let text {
                ZStack(alignment: .trailing) {
                    Text(widest).hidden()
                    Text(text)
                }
                .font(Theme.StatusItem.font)
                .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var text: String? {
        switch content {
        case .iconOnly: nil
        case .modelCount: modelCount == 0 ? nil : "\(modelCount)"
        case .modelMemory: modelBytes == 0 ? nil : Formatting.compactBytes(modelBytes)
        }
    }

    private var widest: String {
        content == .modelCount ? Theme.StatusItem.widestCount : Theme.StatusItem.widestMemory
    }

    private var accessibilityText: String {
        if modelCount == 0 { return "GyozaVitals, nothing loaded" }
        return "GyozaVitals, \(modelCount) loaded, \(Formatting.bytes(modelBytes))"
    }

    /// Drawn once from `GyozaGlyph` at 2x; alpha only, so the system tints it
    /// for Clear and Tinted menu bars. Falls back to an SF Symbol if the
    /// renderer gives nothing.
    static let glyph: NSImage = {
        let size = Theme.StatusItem.glyphSize
        let glyph = GyozaGlyph(grid: size, stroke: Theme.StatusItem.stroke, pleat: Theme.StatusItem.pleat)
        let renderer = ImageRenderer(content: glyph.fill(Theme.ink).frame(width: size, height: size))
        renderer.scale = 2
        if let image = renderer.nsImage {
            image.isTemplate = true
            image.size = NSSize(width: size, height: size)
            return image
        }
        let fallback = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "GyozaVitals") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }()
}

/// A little gyoza: a plump half-moon with rounded corners, three short
/// pleat marks crimped along its arc, resting on a short plate. Designed on
/// an 18 pt grid, 1.5 pt stroke, round caps and joins.
nonisolated struct GyozaGlyph: Shape {
    /// The design grid the measurements below are in (18 pt).
    let grid: CGFloat
    let stroke: CGFloat
    let pleat: CGFloat

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / grid
        let center = CGPoint(x: rect.midX, y: rect.minY + 11 * unit)
        let radius = 7 * unit
        let corner = 2.25 * unit
        let plateY = rect.minY + 15.25 * unit

        func onArc(_ degrees: Double, _ r: CGFloat) -> CGPoint {
            let angle = degrees * .pi / 180
            return CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
        }

        // The body: along the flat bottom, round the right corner, over the
        // top from right to left, round the left corner, close.
        var body = Path()
        body.move(to: CGPoint(x: center.x, y: center.y))
        body.addArc(tangent1End: CGPoint(x: center.x + radius, y: center.y),
                    tangent2End: CGPoint(x: center.x + radius, y: center.y - corner), radius: corner)
        let steps = 40
        let from = -18.0, to = -162.0
        for step in 0...steps {
            body.addLine(to: onArc(from + (to - from) * Double(step) / Double(steps), radius))
        }
        body.addArc(tangent1End: CGPoint(x: center.x - radius, y: center.y),
                    tangent2End: CGPoint(x: center.x, y: center.y), radius: corner)
        body.closeSubpath()
        // The plate.
        body.move(to: CGPoint(x: center.x - 4.5 * unit, y: plateY))
        body.addLine(to: CGPoint(x: center.x + 4.5 * unit, y: plateY))
        var result = body.strokedPath(StrokeStyle(lineWidth: stroke * unit, lineCap: .round, lineJoin: .round))

        // Three pleats, crimped mostly inward so they read as folds, not spikes.
        var pleats = Path()
        for degrees in [-122.0, -90, -58] {
            pleats.move(to: onArc(degrees, radius - 2.5 * unit))
            pleats.addLine(to: onArc(degrees, radius + 0.25 * unit))
        }
        result.addPath(pleats.strokedPath(StrokeStyle(lineWidth: pleat * unit, lineCap: .round)))
        return result
    }
}
