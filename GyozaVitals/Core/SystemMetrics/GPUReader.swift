import Foundation
import IOKit

/// The GPU's own counters from the IORegistry: the first `IOAccelerator`
/// service that publishes a `PerformanceStatistics` dictionary.
///
/// Absence is normal: some chips on macOS 26 publish no utilization, a CI
/// runner has no accelerator service at all. Both give nil, and the UI hides
/// the row rather than showing 0.
nonisolated struct GPUReader: Sendable {
    static let serviceName = "IOAccelerator"
    static let statisticsKey = "PerformanceStatistics"
    static let utilizationKeys = ["Device Utilization %", "GPU Activity(%)"]
    static let inUseMemoryKey = "In use system memory"

    /// Raw (unsmoothed) reading, nil when nothing is published.
    static func read() -> GPUSnapshot? {
        guard let statistics = readStatistics() else { return nil }
        return snapshot(from: statistics)
    }

    /// Picks the fields out of a `PerformanceStatistics` dictionary. A missing
    /// key gives a nil field; both missing gives nil, there is nothing to show.
    static func snapshot(from statistics: [String: Any]) -> GPUSnapshot? {
        var utilization: Double? = nil
        for key in utilizationKeys {
            if let value = number(statistics[key]) {
                utilization = min(1, max(0, value / 100))
                break
            }
        }
        var inUse: UInt64? = nil
        if let value = number(statistics[inUseMemoryKey]), value >= 0 {
            inUse = UInt64(value)
        }
        guard utilization != nil || inUse != nil else { return nil }
        return GPUSnapshot(utilization: utilization, inUseBytes: inUse)
    }

    /// Walks the matching services and returns the first statistics dictionary.
    static func readStatistics() -> [String: Any]? {
        guard let matching = IOServiceMatching(serviceName) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var found: [String: Any]? = nil
        while found == nil {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            if let property = IORegistryEntryCreateCFProperty(entry, statisticsKey as CFString, kCFAllocatorDefault, 0) {
                found = property.takeRetainedValue() as? [String: Any]
            }
        }
        return found
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let double as Double: double
        case let int as Int: Double(int)
        default: nil
        }
    }
}
