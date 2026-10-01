import SwiftUI

/// POWER: one line. "Power adapter" or "Battery 64% · 5 h 12 min", then
/// "· charging" and "· Low Power Mode" when they apply.
struct PowerSection: View {
    let power: PowerSnapshot?

    var body: some View {
        PopoverSection("Power") {
            Text(line)
                .font(Theme.Typeface.meta)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .frame(height: Theme.Layout.textRow)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var line: String {
        guard let power else { return "–" }
        var parts: [String] = []
        if power.onBattery {
            var battery = "Battery"
            if let percent = power.batteryPercent { battery += " \(percent)%" }
            parts.append(battery)
            if let minutes = power.minutesToEmpty, minutes > 0 {
                let h = minutes / 60, m = minutes % 60
                parts.append(h > 0 ? "\(h) h \(m) min" : "\(m) min")
            }
        } else {
            parts.append("Power adapter")
        }
        if power.isCharging { parts.append("charging") }
        if power.lowPowerMode { parts.append("Low Power Mode") }
        return parts.joined(separator: " · ")
    }
}
