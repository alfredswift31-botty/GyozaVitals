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

    /// "4:12" or "1:04:12" for a remaining interval; "now" once it's past.
    static func countdown(to date: Date, from now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        guard seconds > 0 else { return "now" }
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "14:02" for the activity log.
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
