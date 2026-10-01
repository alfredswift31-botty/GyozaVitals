import SwiftUI

/// MEMORY: one stacked bar (app / wired / compressed), the legend, the
/// pressure strip, and one line: the headroom while pressure is normal, or
/// the pressure level's word.
struct MemorySection: View {
    let memory: MemorySnapshot?
    /// The runtimes' footprints, what the MODELS column shows.
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
                statusLine
                    .frame(height: Theme.Layout.textRow)
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

    private var legend: some View {
        let widths = Theme.Layout.legendColumns
        return HStack(spacing: 0) {
            MetaPair(label: "Models", value: memory == nil ? Self.dash : Formatting.bytes(modelBytes), monospaced: true)
                .frame(width: widths[0], alignment: .leading)
            MetaPair(label: "App", value: value(\.appBytes), monospaced: true)
                .frame(width: widths[1], alignment: .leading)
            MetaPair(label: "Wired", value: value(\.wiredBytes), monospaced: true)
                .frame(width: widths[2], alignment: .leading)
            MetaPair(label: "Compressed", value: value(\.compressedBytes), monospaced: true)
                .frame(width: widths[3], alignment: .leading)
            MetaPair(label: "Swap", value: value(\.swapUsedBytes), monospaced: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
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

    private var meterValue: String {
        guard let memory else { return "unknown" }
        return "\(Formatting.bytes(memory.usedBytes)) of \(Formatting.bytes(memory.totalBytes)) used, pressure \(memory.pressure.rawValue)"
    }

    private var stripValue: String {
        let known = history.samples.compactMap { $0 }
        guard let last = known.last else { return "no samples yet" }
        let critical = known.filter { $0 == .critical }.count
        return "now \(last.rawValue), \(critical) critical of the last \(known.count) samples"
    }
}
