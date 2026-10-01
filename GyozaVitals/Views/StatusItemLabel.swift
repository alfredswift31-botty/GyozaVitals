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

/// A little gyoza: a rounded half-moon, three pleat ticks on its arc, over a
/// short baseline. Designed on an 18 pt grid, 1.5 pt stroke, round caps.
nonisolated struct GyozaGlyph: Shape {
    /// The design grid the measurements below are in (18 pt).
    let grid: CGFloat
    let stroke: CGFloat
    let pleat: CGFloat

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / grid
        let center = CGPoint(x: rect.midX, y: rect.minY + 11.25 * unit)
        let radius = 6.5 * unit

        // The half-moon, as a polyline through the arc so the direction is unambiguous.
        var body = Path()
        let steps = 36
        for step in 0...steps {
            let angle = Double.pi + Double.pi * Double(step) / Double(steps)
            let point = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
            if step == 0 { body.move(to: point) } else { body.addLine(to: point) }
        }
        body.closeSubpath()
        // The plate.
        body.move(to: CGPoint(x: center.x - 4 * unit, y: rect.minY + 15.5 * unit))
        body.addLine(to: CGPoint(x: center.x + 4 * unit, y: rect.minY + 15.5 * unit))
        var result = body.strokedPath(StrokeStyle(lineWidth: stroke * unit, lineCap: .round, lineJoin: .round))

        // Three pleats crossing the arc.
        var pleats = Path()
        for degrees in [-125.0, -90, -55] {
            let angle = degrees * .pi / 180
            let direction = CGPoint(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)))
            let inner = CGPoint(x: center.x + direction.x * (radius - 1.5 * unit), y: center.y + direction.y * (radius - 1.5 * unit))
            let outer = CGPoint(x: center.x + direction.x * (radius + 1.25 * unit), y: center.y + direction.y * (radius + 1.25 * unit))
            pleats.move(to: inner)
            pleats.addLine(to: outer)
        }
        result.addPath(pleats.strokedPath(StrokeStyle(lineWidth: pleat * unit, lineCap: .round)))
        return result
    }
}
