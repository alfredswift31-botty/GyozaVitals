import Foundation

/// Numbers the way the popover shows them: one decimal GB, whole percent,
/// and a compact form for the menu bar.
nonisolated enum Formatting {
    /// "6.1 GB", "274 MB".
    static func bytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(value) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    /// "12.4G" for the status item; "0.3G" below a gigabyte so the width is stable.
    static func compactBytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        return String(format: "%.1fG", gb)
    }

    /// "61%".
    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", (fraction * 100).rounded())
    }

    /// Beyond this a runtime means "kept loaded": Ollama's keep_alive -1 is
    /// an expiry decades away, not a timer anyone wants to read.
    static let countdownLimit: TimeInterval = 30 * 86_400

    /// "4:12" or "1:04:12" for a remaining interval; "now" once it's past;
    /// "kept" when it is more than `countdownLimit` away.
    static func countdown(to date: Date, from now: Date = Date()) -> String {
        let remaining = date.timeIntervalSince(now)
        guard remaining < countdownLimit else { return "kept" }
        let seconds = Int(remaining.rounded())
        guard seconds > 0 else { return "now" }
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "14:02" for the activity log.
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "14:02:37" for the diagnostics pane.
    static func clockWithSeconds(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// A 0...1 fraction to a fixed number of decimals ("0.012", "1.00"),
    /// or an en dash for nil: the diagnostics pane never shows a 0 that
    /// means "unknown".
    static func fraction(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "\u{2013}" }
        return String(format: "%.\(decimals)f", value)
    }
}
