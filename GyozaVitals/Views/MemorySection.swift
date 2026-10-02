import SwiftUI

/// MEMORY: one stacked bar (app / wired / compressed), a legend of exactly
/// those parts plus the remainder (free), the pressure strip, and two fixed
/// rows: the headroom or pressure word, then a quiet line for what the bar
/// cannot show, the runtimes' footprint (it overlaps app and wired: on Apple
/// silicon GPU buffers count as wired) and swap (disk, not RAM).
struct MemorySection: View {
    let memory: MemorySnapshot?
    /// The runtimes' footprints, what the "models" figure in the meta line shows.
    let modelBytes: UInt64
    @ObservedObject var history: PressureHistory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dash = "–"

    var body: some View {
        PopoverSection("Memory") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Meter(stacked: segments)
                    .animation(reduceMotion ? nil : Theme.Motion.calm, value: segments)
                    .accessibilityLabel("Memory")
                    .accessibilityValue(meterValue)
                    .accessibilityAddTraits(.updatesFrequently)
                legend
                PressureStrip(samples: history.samples)
                    .accessibilityLabel("Memory pressure history")
                    .accessibilityValue(stripValue)
                // Two rows of fixed height: the popover must not move on a tick.
                VStack(alignment: .leading, spacing: 0) {
                    statusLine
                        .frame(height: Theme.Layout.textRow, alignment: .leading)
                    Text(metaLine)
                        .font(Theme.Typeface.meta)
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                        .frame(height: Theme.Layout.textRow, alignment: .leading)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
    }

    private var segments: [Meter.Segment] {
        guard let memory, memory.totalBytes > 0 else { return [] }
        let total = Double(memory.totalBytes)
        let critical = memory.pressure == .critical
        return [
            Meter.Segment(fraction: Double(memory.appBytes) / total, fill: .ink(opacity: Theme.Emphasis.primary)),
            Meter.Segment(fraction: Double(memory.wiredBytes) / total, fill: .ink(opacity: Theme.Emphasis.secondary)),
            // The compressor is what pressure drives; under critical pressure its share is the live one.
            Meter.Segment(fraction: Double(memory.compressedBytes) / total,
                          fill: critical ? .live : .ink(opacity: Theme.Emphasis.tertiary)),
        ]
    }

    /// The bar's three segments in order, then the remainder: four equal
    /// columns on the 77 pt grid, so the legend reads as the bar.
    private var legend: some View {
        HStack(spacing: 0) {
            MetaPair(label: "App", value: value(\.appBytes), monospaced: true)
                .frame(width: Theme.Layout.column, alignment: .leading)
            MetaPair(label: "Wired", value: value(\.wiredBytes), monospaced: true)
                .frame(width: Theme.Layout.column, alignment: .leading)
            MetaPair(label: "Compressed", value: value(\.compressedBytes), monospaced: true)
                .frame(width: Theme.Layout.column, alignment: .leading)
            MetaPair(label: "Free", value: value(\.freeBytes), monospaced: true)
                .frame(width: Theme.Layout.column, alignment: .leading)
        }
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func value(_ key: KeyPath<MemorySnapshot, UInt64>) -> String {
        guard let memory else { return Self.dash }
        return Formatting.bytes(memory[keyPath: key])
    }

    @ViewBuilder
    private var statusLine: some View {
        switch memory?.pressure {
        case .none:
            Text(Self.dash)
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.inkTertiary)
        case .normal:
            if let headroom = memory?.headroomBytes {
                Text("room for ~\(Formatting.bytes(headroom)) more before pressure")
                    .font(Theme.Typeface.meta)
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
        case .warning:
            Text("warning")
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.inkSecondary)
        case .critical:
            Text("critical")
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.live)
        }
    }

    /// "models 6.0 GB · swap 4.5 GB"; the swap part only while swap is in
    /// use; "no model memory" when there is neither.
    private var metaLine: String {
        guard let memory else { return Self.dash }
        var parts: [String] = []
        if modelBytes > 0 { parts.append("models \(Formatting.bytes(modelBytes))") }
        if memory.swapUsedBytes > 0 { parts.append("swap \(Formatting.bytes(memory.swapUsedBytes))") }
        return parts.isEmpty ? "no model memory" : parts.joined(separator: " · ")
    }

    private var meterValue: String {
        guard let memory else { return "unknown" }
        return "\(Formatting.bytes(memory.usedBytes)) of \(Formatting.bytes(memory.totalBytes)) used, "
            + "\(Formatting.bytes(memory.freeBytes)) free, pressure \(memory.pressure.rawValue), \(metaLine)"
    }

    private var stripValue: String {
        let known = history.samples.compactMap { $0 }
        guard let last = known.last else { return "no samples yet" }
        let critical = known.filter { $0 == .critical }.count
        return "now \(last.rawValue), \(critical) critical of the last \(known.count) samples"
    }
}
