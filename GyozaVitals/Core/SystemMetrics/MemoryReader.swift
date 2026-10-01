import Darwin
import Foundation

/// Reads physical memory the way Activity Monitor reports it: `host_statistics64`
/// for the page counts, `vm.swapusage` for swap, and
/// `kern.memorystatus_vm_pressure_level` for pressure.
nonisolated struct MemoryReader: Sendable {
    /// The page counts the formula needs, pulled out of `vm_statistics64` so
    /// the arithmetic can be tested with synthetic values.
    nonisolated struct Pages: Hashable, Sendable {
        var active: UInt64
        var inactive: UInt64
        var speculative: UInt64
        var wired: UInt64
        var compressed: UInt64
        var purgeable: UInt64
        var external: UInt64

        init(active: UInt64, inactive: UInt64, speculative: UInt64, wired: UInt64,
             compressed: UInt64, purgeable: UInt64, external: UInt64) {
            self.active = active
            self.inactive = inactive
            self.speculative = speculative
            self.wired = wired
            self.compressed = compressed
            self.purgeable = purgeable
            self.external = external
        }

        init(_ stats: vm_statistics64_data_t) {
            self.init(active: UInt64(stats.active_count),
                      inactive: UInt64(stats.inactive_count),
                      speculative: UInt64(stats.speculative_count),
                      wired: UInt64(stats.wire_count),
                      compressed: UInt64(stats.compressor_page_count),
                      purgeable: UInt64(stats.purgeable_count),
                      external: UInt64(stats.external_page_count))
        }
    }

    /// One reading. Every field falls back to a safe value (0, `.normal`) if
    /// its call fails; `totalBytes` always comes from ProcessInfo.
    static func read(host: mach_port_t) -> MemorySnapshot {
        let total = ProcessInfo.processInfo.physicalMemory
        let pageSize = Self.pageSize(host: host)
        let pages = Self.readPages(host: host) ?? Pages(active: 0, inactive: 0, speculative: 0, wired: 0,
                                                        compressed: 0, purgeable: 0, external: 0)
        let swap = Self.readSwap()
        let pressure = Self.readPressure()
        return snapshot(pages: pages, pageSize: pageSize, totalBytes: total,
                        swapUsedBytes: swap.used, swapTotalBytes: swap.total, pressure: pressure)
    }

    /// Activity Monitor's arithmetic, in pages:
    /// used = active + inactive + speculative + wired + compressed − purgeable − external,
    /// app = used − wired − compressed, cached = purgeable + external.
    /// Clamped so that app + wired + compressed == used <= total even when the
    /// kernel's counters were read mid-update.
    ///
    /// `modelBytes` is 0 here: this reader knows nothing about the runtimes.
    /// The store and UI use `VitalsStore.modelBytes` (the sum of runtime
    /// footprints from the scanner) instead.
    static func snapshot(pages: Pages, pageSize: UInt64, totalBytes: UInt64,
                         swapUsedBytes: UInt64, swapTotalBytes: UInt64, pressure: MemoryPressure) -> MemorySnapshot {
        let resident = pages.active + pages.inactive + pages.speculative + pages.wired + pages.compressed
        let reclaimable = pages.purgeable + pages.external
        var usedPages = resident > reclaimable ? resident - reclaimable : 0
        let pinnedPages = pages.wired + pages.compressed
        if usedPages < pinnedPages { usedPages = pinnedPages }

        // Nothing can exceed RAM. Clamp in order of certainty: wired and
        // compressed are definitely resident, app memory takes the remainder.
        let used = min(usedPages * pageSize, totalBytes)
        let wired = min(pages.wired * pageSize, used)
        let compressed = min(pages.compressed * pageSize, used - wired)
        let app = used - wired - compressed
        let cached = min(reclaimable * pageSize, totalBytes)
        return MemorySnapshot(totalBytes: totalBytes, usedBytes: used, appBytes: app, wiredBytes: wired,
                              compressedBytes: compressed, cachedBytes: cached,
                              swapUsedBytes: swapUsedBytes, swapTotalBytes: swapTotalBytes,
                              pressure: pressure, modelBytes: 0)
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    static func pressure(fromLevel level: Int32) -> MemoryPressure {
        switch level {
        case ..<2: .normal
        case 2..<4: .warning
        default: .critical
        }
    }

    // MARK: Raw reads

    static func readPages(host: mach_port_t) -> Pages? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Pages(stats)
    }

    static func pageSize(host: mach_port_t) -> UInt64 {
        var size: vm_size_t = 0
        if host_page_size(host, &size) == KERN_SUCCESS, size > 0 { return UInt64(size) }
        return UInt64(getpagesize())
    }

    static func readSwap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// Falls back to `.normal` when the sysctl is unavailable, which it never
    /// is on a supported macOS; the store logs transitions, not levels.
    static func readPressure() -> MemoryPressure {
        guard let level = Sysctl.int32("kern.memorystatus_vm_pressure_level") else { return .normal }
        return pressure(fromLevel: level)
    }
}
