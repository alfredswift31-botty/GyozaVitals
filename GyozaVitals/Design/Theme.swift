import AppKit
import SwiftUI

/// GyozaVitals' design system (shared with GyozaYap): Swiss / International Typographic style.
/// Monochrome, one typeface family (San Francisco) doing all the work through
/// size and weight, small bold uppercase labels over plain values, hairlines
/// instead of boxes, and one colour, red, reserved for "live". Every screen
/// builds from these tokens; see docs/DESIGN.md for the rules.
enum Theme {
    // MARK: Colour

    /// A colour with a light and a dark value.
    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? false
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    /// The page: near-black in dark mode, off-white in light. Never pure.
    static let canvas = dynamic(light: 0xF5F5F4, dark: 0x111111)
    /// Fields and the few raised surfaces (text inputs, the notes pad).
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1A1A1A)
    /// Primary text and the primary button.
    static let ink = dynamic(light: 0x111111, dark: 0xF2F2F0)
    /// Secondary text: values under labels, descriptions. AA on canvas.
    static let inkSecondary = dynamic(light: 0x5C5C59, dark: 0xA3A3A0)
    /// Tertiary text: labels, timestamps, footnotes. Use at label sizes only.
    static let inkTertiary = dynamic(light: 0x7A7A76, dark: 0x7D7D7A)
    /// 1 pt dividers and outlines.
    static let hairline = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.12)
    /// Hover and selection washes.
    static let wash = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.07)
    /// Text on an `ink` fill (the primary button, a selected row).
    static let inkInverse = dynamic(light: 0xF5F5F4, dark: 0x111111)
    /// The only colour: recording is live. Also destructive actions.
    static let live = dynamic(light: 0xD7263D, dark: 0xFF4D5E)

    // MARK: Type (San Francisco, one family)

    enum Typeface {
        /// One or two lowercase words carrying a screen: an empty state, the recording clock.
        static let display = Font.system(size: 56, weight: .medium)
        static let displayTracking: CGFloat = -2.2
        /// A meeting's title.
        static let title = Font.system(size: 28, weight: .semibold)
        static let titleTracking: CGFloat = -0.8
        /// A statement inside content (a TL;DR, an answer).
        static let lead = Font.system(size: 17, weight: .medium)
        static let leadTracking: CGFloat = -0.2
        /// Sidebar row titles, list item emphasis.
        static let heading = Font.system(size: 13.5, weight: .semibold)
        /// Running text.
        static let body = Font.system(size: 13.5)
        static let bodyLineSpacing: CGFloat = 4
        /// Values under a label, secondary lines.
        static let meta = Font.system(size: 12)
        /// Small bold uppercase labels: the poster's column headers.
        static let label = Font.system(size: 10.5, weight: .bold)
        static let labelTracking: CGFloat = 0.8
        /// Timestamps and durations: fixed width so columns line up.
        static let mono = Font.system(size: 11.5, design: .monospaced)
    }

    // MARK: Space, shape, motion

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
        /// Page margin of the detail and recording panes.
        static let page: CGFloat = 40
        /// Readable measure for running text.
        static let measure: CGFloat = 640
    }

    /// One radius scale, used everywhere: controls 5, containers 8. Nothing is a pill.
    enum Radius {
        static let control: CGFloat = 5
        static let container: CGFloat = 8
    }

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.18)
        static let calm = Animation.easeOut(duration: 0.3)
        static let pressedScale: CGFloat = 0.98
    }

    // MARK: GyozaVitals additions (docs/DESIGN.md "Measurements")

    /// Ink opacities for stacked data: the first series full, the rest fading.
    enum Emphasis {
        static let primary: Double = 1
        static let secondary: Double = 0.55
        static let tertiary: Double = 0.25
        /// A trace: a normal sample in the pressure strip.
        static let trace: Double = 0.12
    }

    /// The meters: one 6 pt bar, one 4 pt strip.
    enum Gauge {
        static let barHeight: CGFloat = 6
        /// Ruler marks under the bar at 25/50/75 %.
        static let tickHeight: CGFloat = 3
        static let ticks: [Double] = [0.25, 0.5, 0.75]
        static let stripHeight: CGFloat = 4
        static let stripSamples = 60
        /// Canvas showing between stacked segments and strip samples.
        static let gap: CGFloat = 1
    }

    /// The popover's grid.
    enum Layout {
        static let popoverWidth: CGFloat = 340
        static let settingsWidth: CGFloat = 520
        /// Tall enough for the four settings sections on a 13-inch display;
        /// the diagnostics section below them scrolls into view.
        static let settingsHeight: CGFloat = 860
        /// Label-over-value column: four to a row. The memory legend is four
        /// of these (APP / WIRED / COMPR. / FREE), filling the 308 pt content column.
        static let column: CGFloat = 77
        static let labelRow: CGFloat = 20
        static let textRow: CGFloat = 16
        static let modelRow: CGFloat = 44
        static let footerRow: CGFloat = 36
        static let activityRows = 5
        static let modelRowsBeforeScrolling = 8
    }

    /// The status item: a template glyph and one mono number.
    enum StatusItem {
        static let glyphSize: CGFloat = 18
        static let stroke: CGFloat = 1.5
        static let pleat: CGFloat = 1
        static let font = Font.system(size: 12).monospacedDigit()
        /// The widest number the slot must hold.
        static let widestMemory = "99.9G"
        static let widestCount = "99"
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Text styles

extension View {
    /// Small bold uppercase label, as in the poster's column headers.
    func labelStyle() -> some View {
        self.font(Theme.Typeface.label)
            .tracking(Theme.Typeface.labelTracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.inkTertiary)
    }

    /// Large lowercase display type.
    func displayStyle() -> some View {
        self.font(Theme.Typeface.display)
            .tracking(Theme.Typeface.displayTracking)
            .foregroundStyle(Theme.ink)
    }

    func titleStyle() -> some View {
        self.font(Theme.Typeface.title)
            .tracking(Theme.Typeface.titleTracking)
            .foregroundStyle(Theme.ink)
    }

    func bodyStyle() -> some View {
        self.font(Theme.Typeface.body)
            .lineSpacing(Theme.Typeface.bodyLineSpacing)
            .foregroundStyle(Theme.ink)
    }
}

// MARK: - Components

/// A label over a value: the poster's metadata columns (DATE / 12 Sep 2026).
struct MetaPair: View {
    let label: String
    let value: String
    var monospaced = false
    /// The value's colour when it must not be plain ink: `Theme.live` for a critical state.
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).labelStyle()
            Text(value)
                .font(monospaced ? Theme.Typeface.mono : Theme.Typeface.meta)
                .monospacedDigit()
                .foregroundStyle(tint ?? Theme.ink)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A 1 pt divider in the hairline colour.
struct Hairline: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

/// A section header: a label with a hairline running to the right edge.
struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(title).labelStyle().fixedSize()
            Hairline()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A keyboard shortcut drawn as a key.
struct KeyCap: View {
    let keys: String

    init(_ keys: String) {
        self.keys = keys
    }

    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(Theme.hairline))
            .accessibilityLabel("Shortcut \(keys)")
    }
}

/// A small red dot that breathes while recording; still when Reduce Motion is on.
struct LiveDot: View {
    var isLive = true
    var size: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(isLive ? Theme.live : Theme.inkTertiary)
            .frame(width: size, height: size)
            .opacity(isLive && dim && !reduceMotion ? 0.35 : 1)
            .onAppear {
                guard isLive, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityLabel(isLive ? "Recording" : "Not recording")
    }
}

/// An empty or waiting screen: one large lowercase word, one line of plain
/// text, at most one action. Left-aligned on the page grid, like the poster.
struct EmptyState<Action: View>: View {
    let word: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(word).displayStyle()
            Text(message)
                .font(Theme.Typeface.body)
                .lineSpacing(Theme.Typeface.bodyLineSpacing)
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            action()
                .padding(.top, Theme.Space.s)
        }
        .padding(Theme.Space.page)
        // A floor on the width: measured very narrow, the wrapping message asks
        // for more height than the window has and a split view lays out off screen.
        .frame(minWidth: 360 + 2 * Theme.Space.page, maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

extension EmptyState where Action == EmptyView {
    init(word: String, message: String) {
        self.init(word: word, message: message) { EmptyView() }
    }
}

// MARK: - Buttons

/// The one filled button on a screen: ink fill, inverse text, crisp corners.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.inkInverse)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(tint.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .scaleEffect(configuration.isPressed ? Theme.Motion.pressedScale : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

/// Everything else: text on a hairline outline, washed when pressed.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? Theme.wash : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline))
            .scaleEffect(configuration.isPressed ? Theme.Motion.pressedScale : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    /// The destructive or "stop recording" button.
    static var live: PrimaryButtonStyle { PrimaryButtonStyle(tint: Theme.live) }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

// MARK: - Fields

extension View {
    /// A text field or editor on the surface colour with a hairline edge.
    func fieldSurface() -> some View {
        self.padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline))
    }
}

// MARK: - Meters (GyozaVitals)

/// A 6 pt bar: track in `wash`, fill in `ink`, square corners, with ruler
/// marks under it at 25/50/75 %. The stacked form draws several fills at
/// falling ink opacity, 1 pt of canvas between them; a segment may be `live`.
struct Meter: View {
    struct Segment: Equatable {
        enum Fill: Equatable {
            case ink(opacity: Double)
            case live
        }
        var fraction: Double
        var fill: Fill
    }

    let segments: [Segment]
    var ticks: [Double] = Theme.Gauge.ticks

    init(fraction: Double) {
        segments = [Segment(fraction: fraction, fill: .ink(opacity: Theme.Emphasis.primary))]
    }

    init(stacked segments: [Segment]) {
        self.segments = segments
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.wash)
                    .frame(height: Theme.Gauge.barHeight)
                HStack(spacing: Theme.Gauge.gap) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(color(for: segment.fill))
                            .frame(width: max(0, width * min(max(segment.fraction, 0), 1) - Theme.Gauge.gap))
                    }
                }
                .frame(height: Theme.Gauge.barHeight)
                ForEach(ticks, id: \.self) { tick in
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(width: 1, height: Theme.Gauge.tickHeight)
                        .offset(x: (width * tick).rounded() - 0.5, y: Theme.Gauge.barHeight + Theme.Gauge.gap)
                }
            }
        }
        .frame(height: Theme.Gauge.barHeight + (ticks.isEmpty ? 0 : Theme.Gauge.gap + Theme.Gauge.tickHeight))
        .accessibilityElement(children: .ignore)
    }

    private func color(for fill: Segment.Fill) -> Color {
        switch fill {
        case .ink(let opacity): Theme.ink.opacity(opacity)
        case .live: Theme.live
        }
    }
}

/// Sixty samples of memory pressure, oldest on the left, 4 pt tall. Ink
/// opacity follows the level; a critical sample is `live`; no sample is wash.
struct PressureStrip: View {
    /// Oldest first. Fewer than sixty are right-aligned; more keep the last sixty.
    let samples: [MemoryPressure?]

    var body: some View {
        Canvas { context, size in
            let count = Theme.Gauge.stripSamples
            let recent = Array(samples.suffix(count))
            let padded = Array<MemoryPressure?>(repeating: nil, count: max(0, count - recent.count)) + recent
            let step = (size.width + Theme.Gauge.gap) / CGFloat(count)
            for (index, sample) in padded.enumerated() {
                let x = (CGFloat(index) * step).rounded()
                let next = (CGFloat(index + 1) * step).rounded()
                let cell = CGRect(x: x, y: 0, width: max(1, next - x - Theme.Gauge.gap), height: size.height)
                context.fill(Path(cell), with: .color(Self.color(for: sample)))
            }
        }
        .frame(height: Theme.Gauge.stripHeight)
        .accessibilityElement(children: .ignore)
    }

    private static func color(for sample: MemoryPressure?) -> Color {
        switch sample {
        case .none: Theme.wash
        case .normal: Theme.ink.opacity(Theme.Emphasis.trace)
        case .warning: Theme.ink.opacity(Theme.Emphasis.secondary)
        case .critical: Theme.live
        }
    }
}
