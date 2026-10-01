import SwiftUI

/// PROCESSOR: numbers only, four columns to a row. CPU with its P/E split
/// and the load average; then GPU and its memory (absent, not zero, when
/// the OS doesn't report them) and the thermal state as a word.
struct ProcessorSection: View {
    let cpu: CPUSnapshot?
    let gpu: GPUSnapshot?
    let thermal: ThermalLevel?

    private static let dash = "–"

    var body: some View {
        PopoverSection("Processor") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: 0) {
                    column("CPU", cpu.map { Formatting.percent($0.total) })
                    column("P-cores", cpu?.performanceCores.map(Formatting.percent))
                    column("E-cores", cpu?.efficiencyCores.map(Formatting.percent))
                    column("Load", cpu.map { String(format: "%.1f", $0.loadAverage) })
                }
                HStack(spacing: 0) {
                    if let gpu {
                        column("GPU", gpu.utilization.map(Formatting.percent))
                        column("GPU memory", gpu.inUseBytes.map(Formatting.bytes), span: 2)
                    }
                    column("Thermal", thermal?.rawValue, tint: thermalTint)
                }
            }
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// One label-over-value column; `span` takes more of the four when the label needs it.
    private func column(_ label: String, _ value: String?, tint: Color? = nil, span: Int = 1) -> some View {
        MetaPair(label: label, value: value ?? Self.dash, monospaced: true, tint: value == nil ? nil : tint)
            .frame(width: Theme.Layout.column * CGFloat(span), alignment: .leading)
    }

    private var thermalTint: Color? {
        switch thermal {
        case .serious, .critical: Theme.live
        case .nominal, .fair, .none: nil
        }
    }
}
