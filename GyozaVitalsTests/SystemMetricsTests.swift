import Foundation
import Testing
@testable import GyozaVitals

// MARK: - Pure functions

struct SmoothingTests {
    @Test func firstValuePassesThrough() {
        #expect(SystemMetrics.smooth(previous: nil, next: 0.5) == 0.5)
    }

    @Test func movesThirtyPercentTowardTheNewValue() {
        #expect(abs(SystemMetrics.smooth(previous: 0, next: 1) - 0.3) < 1e-12)
        #expect(abs(SystemMetrics.smooth(previous: 1, next: 0) - 0.7) < 1e-12)
        #expect(SystemMetrics.smooth(previous: 0.5, next: 0.5) == 0.5)
        #expect(abs(SystemMetrics.smooth(previous: 0.2, next: 0.6, alpha: 0.5) - 0.4) < 1e-12)
    }
}

struct MemoryFormulaTests {
    static let pageSize: UInt64 = 16_384
    static let total: UInt64 = 36 * 1_073_741_824

    @Test func activityMonitorArithmetic() {
        let pages = MemoryReader.Pages(active: 500_000, inactive: 300_000, speculative: 10_000, wired: 150_000,
                                       compressed: 100_000, purgeable: 20_000, external: 200_000)
        let memory = MemoryReader.snapshot(pages: pages, pageSize: Self.pageSize, totalBytes: Self.total,
                                           swapUsedBytes: 1_000, swapTotalBytes: 2_000, pressure: .warning)
        // used = 500k + 300k + 10k + 150k + 100k - 20k - 200k = 840k pages
        #expect(memory.usedBytes == 840_000 * Self.pageSize)
        #expect(memory.appBytes == 590_000 * Self.pageSize)
        #expect(memory.wiredBytes == 150_000 * Self.pageSize)
        #expect(memory.compressedBytes == 100_000 * Self.pageSize)
        #expect(memory.cachedBytes == 220_000 * Self.pageSize)
        #expect(memory.freeBytes == Self.total - memory.usedBytes)
        #expect(memory.appBytes + memory.wiredBytes + memory.compressedBytes == memory.usedBytes)
        #expect(memory.swapUsedBytes == 1_000 && memory.swapTotalBytes == 2_000)
        #expect(memory.pressure == .warning)
        #expect(memory.modelBytes == 0)
    }

    @Test func neverUnderflowsOrExceedsRAM() {
        // Reclaimable larger than resident: used floors at wired + compressed.
        let odd = MemoryReader.Pages(active: 10, inactive: 10, speculative: 0, wired: 5, compressed: 5,
                                     purgeable: 100, external: 100)
        let floored = MemoryReader.snapshot(pages: odd, pageSize: Self.pageSize, totalBytes: Self.total,
                                            swapUsedBytes: 0, swapTotalBytes: 0, pressure: .normal)
        #expect(floored.usedBytes == 10 * Self.pageSize)
        #expect(floored.appBytes == 0)
        #expect(floored.appBytes + floored.wiredBytes + floored.compressedBytes == floored.usedBytes)

        // Counters that add up to more than RAM are clamped to RAM.
        let huge = MemoryReader.Pages(active: 10_000_000, inactive: 0, speculative: 0, wired: 100, compressed: 100,
                                      purgeable: 0, external: 0)
        let clamped = MemoryReader.snapshot(pages: huge, pageSize: Self.pageSize, totalBytes: Self.total,
                                            swapUsedBytes: 0, swapTotalBytes: 0, pressure: .normal)
        #expect(clamped.usedBytes == Self.total)
        #expect(clamped.freeBytes == 0)
        #expect(clamped.appBytes + clamped.wiredBytes + clamped.compressedBytes == clamped.usedBytes)
    }

    @Test func pressureLevels() {
        #expect(MemoryReader.pressure(fromLevel: 0) == .normal)
        #expect(MemoryReader.pressure(fromLevel: 1) == .normal)
        #expect(MemoryReader.pressure(fromLevel: 2) == .warning)
        #expect(MemoryReader.pressure(fromLevel: 3) == .warning)
        #expect(MemoryReader.pressure(fromLevel: 4) == .critical)
        #expect(MemoryReader.pressure(fromLevel: 8) == .critical)
    }
}

struct CPUFormulaTests {
    @Test func splitsBusyTicksByCoreKind() {
        let before = [CPUReader.Ticks](repeating: CPUReader.Ticks(user: 100, system: 100, nice: 0, idle: 100), count: 4)
        let after = [
            CPUReader.Ticks(user: 125, system: 125, nice: 0, idle: 150),   // E: 50 busy of 100
            CPUReader.Ticks(user: 150, system: 100, nice: 0, idle: 150),   // E: 50 busy of 100
            CPUReader.Ticks(user: 150, system: 150, nice: 0, idle: 100),   // P: 100 busy of 100
            CPUReader.Ticks(user: 100, system: 100, nice: 100, idle: 100), // P: 100 busy of 100
        ]
        let topology = CPUReader.Topology(logicalCount: 4, performanceCount: 2, efficiencyCount: 2, hasPerformanceLevels: true)
        let utilization = CPUReader.utilization(previous: before, current: after, topology: topology)
        #expect(utilization?.total == 0.75)
        #expect(utilization?.efficiency == 0.5)
        #expect(utilization?.performance == 1.0)
    }

    @Test func intelHasNoSplitAndMismatchHidesIt() {
        let before = [CPUReader.Ticks](repeating: CPUReader.Ticks(user: 0, system: 0, nice: 0, idle: 0), count: 2)
        let after = [CPUReader.Ticks](repeating: CPUReader.Ticks(user: 10, system: 0, nice: 0, idle: 10), count: 2)
        let intel = CPUReader.Topology(logicalCount: 2, performanceCount: 2, efficiencyCount: 0, hasPerformanceLevels: false)
        let flat = CPUReader.utilization(previous: before, current: after, topology: intel)
        #expect(flat?.total == 0.5)
        #expect(flat?.performance == nil && flat?.efficiency == nil)

        let wrong = CPUReader.Topology(logicalCount: 8, performanceCount: 4, efficiencyCount: 4, hasPerformanceLevels: true)
        let hidden = CPUReader.utilization(previous: before, current: after, topology: wrong)
        #expect(hidden?.total == 0.5)
        #expect(hidden?.performance == nil && hidden?.efficiency == nil)
    }

    @Test func toleratesCounterWrapAndNoElapsedTicks() {
        let before = CPUReader.Ticks(user: UInt32.max - 15, system: 0, nice: 0, idle: UInt32.max - 15)
        let after = CPUReader.Ticks(user: 16, system: 0, nice: 0, idle: 16)
        let delta = after.delta(since: before)
        #expect(delta.busy == 32 && delta.total == 64)

        let same = [CPUReader.Ticks(user: 1, system: 1, nice: 1, idle: 1)]
        let topology = CPUReader.Topology(logicalCount: 1, performanceCount: 1, efficiencyCount: 0, hasPerformanceLevels: false)
        #expect(CPUReader.utilization(previous: same, current: same, topology: topology) == nil)
    }
}

struct GPUFormulaTests {
    @Test func readsUtilizationAndMemory() {
        let gpu = GPUReader.snapshot(from: ["Device Utilization %": 42, "In use system memory": 1_234_567_890])
        #expect(gpu?.utilization == 0.42)
        #expect(gpu?.inUseBytes == 1_234_567_890)
    }

    @Test func fallsBackAndHidesWhatIsMissing() {
        let legacy = GPUReader.snapshot(from: ["GPU Activity(%)": 100])
        #expect(legacy?.utilization == 1.0)
        #expect(legacy?.inUseBytes == nil)
        let memoryOnly = GPUReader.snapshot(from: ["In use system memory": 10])
        #expect(memoryOnly?.utilization == nil)
        #expect(memoryOnly?.inUseBytes == 10)
        #expect(GPUReader.snapshot(from: ["Renderer Utilization %": 50]) == nil)
        #expect(GPUReader.snapshot(from: [:]) == nil)
    }
}

struct PowerFormulaTests {
    @Test func noBatteryMeansDesktop() {
        let power = PowerReader.snapshot(from: nil, lowPowerMode: true)
        #expect(power == PowerSnapshot(onBattery: false, batteryPercent: nil, isCharging: false,
                                       lowPowerMode: true, minutesToEmpty: nil))
    }

    @Test func readsTheIOKitDescription() {
        let onBattery = PowerReader.snapshot(from: [
            "Power Source State": "Battery Power", "Current Capacity": 80, "Max Capacity": 100,
            "Is Charging": false, "Time to Empty": 120, "Type": "InternalBattery",
        ], lowPowerMode: false)
        #expect(onBattery == PowerSnapshot(onBattery: true, batteryPercent: 80, isCharging: false,
                                           lowPowerMode: false, minutesToEmpty: 120))

        let charging = PowerReader.snapshot(from: [
            "Power Source State": "AC Power", "Current Capacity": 55, "Max Capacity": 100,
            "Is Charging": true, "Time to Empty": 0,
        ], lowPowerMode: false)
        #expect(charging == PowerSnapshot(onBattery: false, batteryPercent: 55, isCharging: true,
                                          lowPowerMode: false, minutesToEmpty: nil))

        // -1 is "still estimating"; capacity on a non-percent scale is rescaled.
        let estimating = PowerReader.snapshot(from: [
            "Power Source State": "Battery Power", "Current Capacity": 2_500, "Max Capacity": 5_000,
            "Is Charging": false, "Time to Empty": -1,
        ], lowPowerMode: false)
        #expect(estimating.batteryPercent == 50)
        #expect(estimating.minutesToEmpty == nil)
    }
}

struct ThermalMappingTests {
    @Test func mapsEveryState() {
        #expect(ThermalReader.level(for: .nominal) == .nominal)
        #expect(ThermalReader.level(for: .fair) == .fair)
        #expect(ThermalReader.level(for: .serious) == .serious)
        #expect(ThermalReader.level(for: .critical) == .critical)
    }
}

// MARK: - Against the real machine

/// These run on whatever Mac executes the tests, including a CI runner with
/// no battery and possibly no reported GPU, so they check invariants only.
@MainActor
struct SystemMetricsLiveTests {
    @Test func memoryAddsUp() async {
        let memory = (await SystemMetrics().sample()).memory
        #expect(memory.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.totalBytes > 0)
        #expect(memory.usedBytes > 0)
        #expect(memory.usedBytes + memory.freeBytes == memory.totalBytes)
        #expect(memory.appBytes + memory.wiredBytes + memory.compressedBytes <= memory.usedBytes)
        #expect(memory.cachedBytes <= memory.totalBytes)
        #expect(memory.swapUsedBytes <= memory.swapTotalBytes)
        #expect([MemoryPressure.normal, .warning, .critical].contains(memory.pressure))
        #expect(memory.modelBytes == 0)
    }

    @Test func cpuIsInRangeAfterTwoSamples() async {
        let metrics = SystemMetrics()
        _ = await metrics.sample()
        let cpu = (await metrics.sample()).cpu
        #expect((0...1).contains(cpu.total))
        #expect(cpu.loadAverage >= 0)
        let logical = Int(Sysctl.int32("hw.logicalcpu") ?? 0)
        #expect(logical > 0)
        #expect(cpu.performanceCoreCount + cpu.efficiencyCoreCount == logical)
        if cpu.efficiencyCoreCount == 0 {
            // Intel: one kind of core, no split.
            #expect(cpu.performanceCores == nil && cpu.efficiencyCores == nil)
        } else {
            #expect(cpu.performanceCoreCount > 0)
            if let performance = cpu.performanceCores { #expect((0...1).contains(performance)) }
            if let efficiency = cpu.efficiencyCores { #expect((0...1).contains(efficiency)) }
        }
    }

    @Test func gpuIsAbsentOrInRange() async {
        let gpu = (await SystemMetrics().sample()).gpu
        guard let gpu else { return }
        #expect(gpu.utilization != nil || gpu.inUseBytes != nil)
        if let utilization = gpu.utilization { #expect((0...1).contains(utilization)) }
        if let inUse = gpu.inUseBytes { #expect(inUse <= ProcessInfo.processInfo.physicalMemory) }
    }

    @Test func thermalAndPowerAreConsistent() async {
        let snapshot = await SystemMetrics().sample()
        #expect([ThermalLevel.nominal, .fair, .serious, .critical].contains(snapshot.thermal))
        #expect(abs(snapshot.timestamp.timeIntervalSinceNow) < 5)

        let power = snapshot.power
        #expect(power.lowPowerMode == ProcessInfo.processInfo.isLowPowerModeEnabled)
        if let percent = power.batteryPercent {
            #expect((0...100).contains(percent))
        } else {
            // No battery: a desktop or the CI runner.
            #expect(!power.onBattery && !power.isCharging && power.minutesToEmpty == nil)
        }
        if power.onBattery {
            #expect(power.batteryPercent != nil && !power.isCharging)
        } else {
            #expect(power.minutesToEmpty == nil)
        }
        if let minutes = power.minutesToEmpty { #expect(minutes > 0) }
    }
}
