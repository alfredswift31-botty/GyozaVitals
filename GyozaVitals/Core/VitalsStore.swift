import AppKit
import Combine
import Foundation

/// The one object the UI reads. Owns the refresh schedule, merges the
/// sources, and keeps the activity log by diffing successive scans.
@MainActor
final class VitalsStore: ObservableObject {
    @Published private(set) var system: SystemSnapshot?
    @Published private(set) var runtimes: [RuntimeInstance] = []
    @Published private(set) var models: [LoadedModel] = []
    @Published private(set) var events: [ActivityEvent] = []
    @Published private(set) var appleIntelligenceAvailable: Bool?
    @Published private(set) var lastScan: Date?

    /// True while the popover is open: faster refresh.
    @Published var isPopoverOpen = false { didSet { reschedule() } }

    let settings: AppSettings
    private let metrics: SystemMetricsSource
    private let scanner: ModelScanSource
    private var metricsTimer: DispatchSourceTimer?
    private var scanTimer: DispatchSourceTimer?
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []
    static let maxEvents = 50

    init(settings: AppSettings, metrics: SystemMetricsSource, scanner: ModelScanSource) {
        self.settings = settings
        self.metrics = metrics
        self.scanner = scanner
    }

    /// Fixed data for previews and snapshots; never schedules.
    init(settings: AppSettings, system: SystemSnapshot?, runtimes: [RuntimeInstance], models: [LoadedModel],
         events: [ActivityEvent], appleIntelligenceAvailable: Bool? = nil) {
        self.settings = settings
        self.metrics = StaticMetrics(snapshot: system)
        self.scanner = StaticScanner(result: ScanResult(runtimes: runtimes, models: models,
                                                        appleIntelligenceAvailable: appleIntelligenceAvailable))
        self.system = system
        self.runtimes = runtimes
        self.models = models
        self.events = events
        self.appleIntelligenceAvailable = appleIntelligenceAvailable
        self.lastScan = system?.timestamp
    }

    /// Total model memory: the number in the menu bar.
    var modelBytes: UInt64 { runtimes.reduce(0) { $0 + $1.footprintBytes } }

    // MARK: Schedule

    private var started = false

    /// Begins the refresh schedule. Calling it again is a no-op.
    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = true; self?.reschedule() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.reschedule() }
        })
        reschedule()
        Task { await refreshAll() }
    }

    func stop() {
        metricsTimer?.cancel(); metricsTimer = nil
        scanTimer?.cancel(); scanTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        started = false
    }

    private func reschedule() {
        metricsTimer?.cancel(); scanTimer?.cancel()
        guard !sleeping else { return }
        let metricsInterval = isPopoverOpen ? settings.openMetricsInterval : settings.closedMetricsInterval
        let scanInterval = isPopoverOpen ? settings.openScanInterval : settings.closedScanInterval
        metricsTimer = makeTimer(every: metricsInterval) { [weak self] in await self?.refreshMetrics() }
        scanTimer = makeTimer(every: scanInterval) { [weak self] in await self?.refreshScan() }
        if isPopoverOpen { Task { await refreshAll() } }
    }

    private func makeTimer(every seconds: TimeInterval, _ work: @escaping @MainActor () async -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(Int(seconds * 100)))
        timer.setEventHandler { Task { @MainActor in await work() } }
        timer.resume()
        return timer
    }

    // MARK: Refresh

    func refreshAll() async {
        await refreshMetrics()
        await refreshScan()
    }

    func refreshMetrics() async {
        let next = await metrics.sample()
        if let previous = system {
            if previous.memory.pressure != next.memory.pressure {
                switch next.memory.pressure {
                case .warning: record(.pressureWarning, "memory pressure warning")
                case .critical: record(.pressureCritical, "memory pressure critical")
                case .normal: break
                }
            }
            if previous.thermal != next.thermal, next.thermal == .serious || next.thermal == .critical {
                record(.thermal, "thermal state \(next.thermal.rawValue)")
            }
        }
        system = next
    }

    func refreshScan() async {
        let result = await scanner.scan(watched: settings.watchedRuntimes, ports: settings.ports)
        diff(old: models, new: result.models, oldRuntimes: runtimes, newRuntimes: result.runtimes)
        runtimes = result.runtimes
        models = result.models
        appleIntelligenceAvailable = result.appleIntelligenceAvailable
        lastScan = Date()
    }

    private func diff(old: [LoadedModel], new: [LoadedModel], oldRuntimes: [RuntimeInstance], newRuntimes: [RuntimeInstance]) {
        let oldIDs = Set(old.map(\.id)), newIDs = Set(new.map(\.id))
        for model in new where !oldIDs.contains(model.id) {
            record(.loaded, "\(model.name) loaded in \(model.runtime.displayName)")
        }
        let newRuntimePIDs = Set(newRuntimes.map(\.pid))
        for model in old where !newIDs.contains(model.id) {
            // Gone with its runtime: unloaded. Runtime still up: evicted.
            let kind: ActivityKind = newRuntimePIDs.contains(model.pid) ? .evicted : .unloaded
            record(kind, "\(model.name) \(kind == .evicted ? "evicted from" : "unloaded from") \(model.runtime.displayName)")
        }
        let oldPIDs = Set(oldRuntimes.map(\.pid))
        for runtime in newRuntimes where !oldPIDs.contains(runtime.pid) {
            record(.runtimeStarted, "\(runtime.kind.displayName) started")
        }
        for runtime in oldRuntimes where !newRuntimePIDs.contains(runtime.pid) {
            record(.runtimeStopped, "\(runtime.kind.displayName) stopped")
        }
    }

    private func record(_ kind: ActivityKind, _ text: String) {
        events.insert(ActivityEvent(kind: kind, text: text), at: 0)
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
    }
}

// MARK: - Static sources (previews, snapshots)

final class StaticMetrics: SystemMetricsSource {
    let snapshot: SystemSnapshot?
    init(snapshot: SystemSnapshot?) { self.snapshot = snapshot }
    func sample() async -> SystemSnapshot {
        snapshot ?? SystemSnapshot(
            timestamp: Date(),
            memory: MemorySnapshot(totalBytes: 0, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0, cachedBytes: 0,
                                   swapUsedBytes: 0, swapTotalBytes: 0, pressure: .normal, modelBytes: 0),
            cpu: CPUSnapshot(total: 0, performanceCores: nil, efficiencyCores: nil, loadAverage: 0,
                             performanceCoreCount: 0, efficiencyCoreCount: 0),
            gpu: nil, thermal: .nominal,
            power: PowerSnapshot(onBattery: false, batteryPercent: nil, isCharging: false, lowPowerMode: false, minutesToEmpty: nil))
    }
}

final class StaticScanner: ModelScanSource {
    let result: ScanResult
    init(result: ScanResult) { self.result = result }
    func scan(watched: Set<RuntimeKind>, ports: [RuntimeKind: Int]) async -> ScanResult { result }
}
