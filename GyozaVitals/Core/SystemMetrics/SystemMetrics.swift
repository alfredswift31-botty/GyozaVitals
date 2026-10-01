import Darwin
import Foundation

/// The live `SystemMetricsSource`: one `sample()` reads memory, CPU, GPU,
/// thermal and power in a few hundred microseconds, off the main actor, and
/// smooths CPU and GPU with an EMA (α = 0.3) so the numbers do not flicker.
///
/// The object itself lives on the main actor like the store that owns it;
/// the reading and the smoothing state live in a private actor so the main
/// thread never blocks on Mach or IOKit.
final class SystemMetrics: SystemMetricsSource {
    nonisolated static let smoothingAlpha = 0.3

    private let sampler = Sampler()

    init() {}

    func sample() async -> SystemSnapshot {
        await sampler.sample()
    }

    /// Exponential moving average. The first value passes through unsmoothed.
    nonisolated static func smooth(previous: Double?, next: Double, alpha: Double = smoothingAlpha) -> Double {
        guard let previous else { return next }
        return alpha * next + (1 - alpha) * previous
    }
}

/// Holds the between-sample state (CPU ticks, smoothed values) and does the
/// reading on its own executor.
private actor Sampler {
    private let host: mach_port_t = mach_host_self()
    private let topology = CPUReader.readTopology()
    private var previousTicks: [CPUReader.Ticks]?
    private var lastUtilization: CPUReader.Utilization?
    private var smoothedCPU: Double?
    private var smoothedP: Double?
    private var smoothedE: Double?
    private var smoothedGPU: Double?

    func sample() async -> SystemSnapshot {
        let memory = MemoryReader.read(host: host)
        let cpu = await sampleCPU()
        let gpu = sampleGPU()
        let thermal = ThermalReader.read()
        let power = PowerReader.read()
        return SystemSnapshot(timestamp: Date(), memory: memory, cpu: cpu, gpu: gpu, thermal: thermal, power: power)
    }

    /// Differences the tick counters against the previous call. The very first
    /// call has nothing to difference against, so it waits 100 ms for a second
    /// reading rather than reporting an idle machine.
    private func sampleCPU() async -> CPUSnapshot {
        var current = CPUReader.readTicks(host: host)
        if previousTicks == nil, current != nil {
            previousTicks = current
            try? await Task.sleep(for: .milliseconds(100))
            current = CPUReader.readTicks(host: host)
        }
        if let previous = previousTicks, let now = current,
           let utilization = CPUReader.utilization(previous: previous, current: now, topology: topology) {
            lastUtilization = utilization
        }
        if let now = current { previousTicks = now }

        let raw = lastUtilization ?? CPUReader.Utilization(total: 0, performance: nil, efficiency: nil)
        smoothedCPU = SystemMetrics.smooth(previous: smoothedCPU, next: raw.total)
        smoothedP = raw.performance.map { SystemMetrics.smooth(previous: smoothedP, next: $0) }
        smoothedE = raw.efficiency.map { SystemMetrics.smooth(previous: smoothedE, next: $0) }
        return CPUSnapshot(total: smoothedCPU ?? 0,
                           performanceCores: topology.hasPerformanceLevels ? smoothedP : nil,
                           efficiencyCores: topology.hasPerformanceLevels ? smoothedE : nil,
                           loadAverage: CPUReader.loadAverage(),
                           performanceCoreCount: topology.performanceCount,
                           efficiencyCoreCount: topology.efficiencyCount)
    }

    private func sampleGPU() -> GPUSnapshot? {
        guard var gpu = GPUReader.read() else {
            smoothedGPU = nil
            return nil
        }
        if let utilization = gpu.utilization {
            smoothedGPU = SystemMetrics.smooth(previous: smoothedGPU, next: utilization)
            gpu.utilization = smoothedGPU
        } else {
            smoothedGPU = nil
        }
        return gpu
    }
}

/// Typed `sysctlbyname` reads shared by the readers.
nonisolated enum Sysctl {
    static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
