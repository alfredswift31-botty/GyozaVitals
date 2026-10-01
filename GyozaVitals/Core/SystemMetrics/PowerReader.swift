import Foundation
import IOKit
import IOKit.ps

/// Battery and power-source state from `IOPSCopyPowerSourcesInfo`, plus Low
/// Power Mode from ProcessInfo.
///
/// A Mac without a battery (Mac mini, Mac Studio, the CI runner) has no
/// internal battery source: `onBattery` false, `batteryPercent` nil,
/// `minutesToEmpty` nil.
nonisolated struct PowerReader: Sendable {
    static func read() -> PowerSnapshot {
        snapshot(from: readBatteryDescription(), lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Builds the snapshot from one power source's description (nil = no battery).
    static func snapshot(from description: [String: Any]?, lowPowerMode: Bool) -> PowerSnapshot {
        guard let description else {
            return PowerSnapshot(onBattery: false, batteryPercent: nil, isCharging: false,
                                 lowPowerMode: lowPowerMode, minutesToEmpty: nil)
        }
        let state = description[kIOPSPowerSourceStateKey] as? String
        let onBattery = state == kIOPSBatteryPowerValue
        let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false

        var percent: Int? = nil
        if let current = integer(description[kIOPSCurrentCapacityKey]) {
            let maxCapacity = integer(description[kIOPSMaxCapacityKey]) ?? 100
            // macOS reports capacity as a percentage (max 100); scale if not.
            let scaled = maxCapacity > 0 && maxCapacity != 100 ? current * 100 / maxCapacity : current
            percent = min(100, max(0, scaled))
        }

        var minutesToEmpty: Int? = nil
        if onBattery, let minutes = integer(description[kIOPSTimeToEmptyKey]), minutes > 0 {
            // -1 means "still estimating"; 0 is what AC power reports.
            minutesToEmpty = minutes
        }
        return PowerSnapshot(onBattery: onBattery, batteryPercent: percent, isCharging: isCharging && !onBattery,
                             lowPowerMode: lowPowerMode, minutesToEmpty: minutesToEmpty)
    }

    /// The internal battery's description, or nil when there is none.
    static func readBatteryDescription() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else { return nil }
        var fallback: [String: Any]? = nil
        for source in list as NSArray {
            guard let cfDescription = IOPSGetPowerSourceDescription(blob, source as AnyObject)?.takeUnretainedValue(),
                  let description = cfDescription as NSDictionary as? [String: Any] else { continue }
            let type = description[kIOPSTypeKey] as? String
            if type == kIOPSInternalBatteryType { return description }
            if type == nil, fallback == nil { fallback = description }
        }
        return fallback
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let int as Int: int
        default: nil
        }
    }
}
