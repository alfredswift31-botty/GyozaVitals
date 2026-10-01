import Darwin
import Foundation

/// Per-core tick counters from `host_processor_info`, differenced between two
/// samples, plus the P/E split from `hw.nperflevels` and the 1-minute load
/// average from `getloadavg`.
///
/// Assumption: on Apple silicon the kernel numbers efficiency cores first
/// (cpu 0..<efficiencyCount), then performance cores. That is how every M1–M4
/// Mac reports `hw.perflevel1` (efficiency) and `hw.perflevel0` (performance)
/// against the per-cpu tick array. There is no public API that labels a cpu
/// index, so this is the only way to split them.
nonisolated struct CPUReader: Sendable {
    /// One core's cumulative ticks. 32-bit in the kernel, so differences wrap.
    nonisolated struct Ticks: Hashable, Sendable {
        var user: UInt32
        var system: UInt32
        var nice: UInt32
        var idle: UInt32

        var busy: UInt64 { UInt64(user) + UInt64(system) + UInt64(nice) }

        /// Ticks spent since `previous`, tolerant of the 32-bit counters wrapping.
        func delta(since previous: Ticks) -> (busy: UInt64, total: UInt64) {
            let user = UInt64(self.user &- previous.user)
            let system = UInt64(self.system &- previous.system)
            let nice = UInt64(self.nice &- previous.nice)
            let idle = UInt64(self.idle &- previous.idle)
            let busy = user + system + nice
            return (busy, busy + idle)
        }
    }

    /// How the logical cpus split into performance and efficiency cores.
    /// `hasPerformanceLevels` is false on Intel, where there is one kind of core.
    nonisolated struct Topology: Hashable, Sendable {
        var logicalCount: Int
        var performanceCount: Int
        var efficiencyCount: Int
        var hasPerformanceLevels: Bool
    }

    /// Utilizations in 0...1. `performance`/`efficiency` are nil on Intel, and
    /// nil when the tick array does not match the topology (so the UI shows
    /// "unknown" rather than a wrong split).
    nonisolated struct Utilization: Hashable, Sendable {
        var total: Double
        var performance: Double?
        var efficiency: Double?
    }

    /// Reads the counters for every logical cpu. Nil if Mach refuses.
    static func readTicks(host: mach_port_t) -> [Ticks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            let bytes = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), bytes)
        }
        let stride = Int(CPU_STATE_MAX)
        let available = Int(infoCount) / stride
        let cores = min(Int(cpuCount), available)
        var ticks: [Ticks] = []
        ticks.reserveCapacity(cores)
        for core in 0..<cores {
            let base = core * stride
            ticks.append(Ticks(user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                               system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                               nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
                               idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])))
        }
        return ticks
    }

    /// The P/E layout from sysctl. On a machine without performance levels
    /// (Intel) every cpu counts as a performance core and there is no split.
    static func readTopology() -> Topology {
        let logical = Int(Sysctl.int32("hw.logicalcpu") ?? Sysctl.int32("hw.ncpu") ?? 0)
        let levels = Sysctl.int32("hw.nperflevels") ?? 1
        guard levels >= 2,
              let performance = Sysctl.int32("hw.perflevel0.logicalcpu"),
              let efficiency = Sysctl.int32("hw.perflevel1.logicalcpu") else {
            return Topology(logicalCount: logical, performanceCount: logical, efficiencyCount: 0, hasPerformanceLevels: false)
        }
        return Topology(logicalCount: logical, performanceCount: Int(performance), efficiencyCount: Int(efficiency),
                        hasPerformanceLevels: true)
    }

    /// Busy share between two readings. Nil when no ticks elapsed (two reads
    /// within the same scheduler tick), so the caller keeps its last value.
    static func utilization(previous: [Ticks], current: [Ticks], topology: Topology) -> Utilization? {
        let cores = min(previous.count, current.count)
        guard cores > 0 else { return nil }
        var busyAll: UInt64 = 0, totalAll: UInt64 = 0
        var busyE: UInt64 = 0, totalE: UInt64 = 0
        var busyP: UInt64 = 0, totalP: UInt64 = 0
        for core in 0..<cores {
            let delta = current[core].delta(since: previous[core])
            busyAll += delta.busy
            totalAll += delta.total
            if core < topology.efficiencyCount {
                busyE += delta.busy; totalE += delta.total
            } else {
                busyP += delta.busy; totalP += delta.total
            }
        }
        guard totalAll > 0 else { return nil }
        let total = share(busyAll, totalAll)
        let splitMatches = topology.hasPerformanceLevels
            && topology.efficiencyCount + topology.performanceCount == cores
        guard splitMatches else { return Utilization(total: total, performance: nil, efficiency: nil) }
        return Utilization(total: total,
                           performance: totalP > 0 ? share(busyP, totalP) : nil,
                           efficiency: totalE > 0 ? share(busyE, totalE) : nil)
    }

    /// One-minute load average, or 0 if the call fails.
    static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) >= 1 else { return 0 }
        return loads[0]
    }

    private static func share(_ busy: UInt64, _ total: UInt64) -> Double {
        min(1, max(0, Double(busy) / Double(total)))
    }
}
