import Foundation
import Testing
@testable import GyozaVitals

struct FormattingTests {
    @Test func bytesReadAsTheUserExpects() {
        #expect(Formatting.bytes(6_550_000_000) == "6.1 GB")
        #expect(Formatting.bytes(274_000_000) == "261 MB")
        #expect(Formatting.compactBytes(13_300_000_000) == "12.4G")
        #expect(Formatting.compactBytes(300_000_000) == "0.3G")
    }

    @Test func percentIsWhole() {
        #expect(Formatting.percent(0.614) == "61%")
        #expect(Formatting.percent(0.996) == "100%")
    }

    @Test func countdownFormats() {
        let now = Date()
        #expect(Formatting.countdown(to: now.addingTimeInterval(252), from: now) == "4:12")
        #expect(Formatting.countdown(to: now.addingTimeInterval(3_725), from: now) == "1:02:05")
        #expect(Formatting.countdown(to: now.addingTimeInterval(-5), from: now) == "now")
    }
}

@MainActor
struct MemorySnapshotTests {
    @Test func headroomOnlyWhilePressureIsNormal() {
        var memory = Fixtures.quietSystem.memory
        // 36 GiB total, 12 GB used, 6.1 GB cached: free + cached - 10 % reserve.
        let expected = (memory.freeBytes + memory.cachedBytes) - memory.totalBytes / 10
        #expect(memory.headroomBytes == expected)
        memory.pressure = .warning
        #expect(memory.headroomBytes == nil)
    }
}

@MainActor
struct VitalsStoreTests {
    @Test func firstScanSeedsSilently() async {
        let scanner = SequenceScanner(results: [
            ScanResult(runtimes: Fixtures.runtimes, models: Fixtures.models, appleIntelligenceAvailable: nil),
        ])
        let store = VitalsStore(settings: Fixtures.settings(), metrics: StaticMetrics(snapshot: Fixtures.system), scanner: scanner)
        await store.refreshScan()
        #expect(store.events.isEmpty)
        #expect(store.models.count == Fixtures.models.count)
    }

    @Test func diffRecordsLoadsEvictionsAndUnloads() async {
        let settings = Fixtures.settings()
        let scanner = SequenceScanner(results: [
            .empty,
            ScanResult(runtimes: Fixtures.runtimes, models: Fixtures.models, appleIntelligenceAvailable: nil),
            // Ollama still up but hermes3 gone: evicted. whisper gone with its process: unloaded.
            ScanResult(runtimes: Fixtures.runtimes.filter { $0.kind != .whisper },
                       models: Fixtures.models.filter { $0.name != "hermes3:8b" && $0.runtime != .whisper },
                       appleIntelligenceAvailable: nil),
        ])
        let store = VitalsStore(settings: settings, metrics: StaticMetrics(snapshot: Fixtures.system), scanner: scanner)
        await store.refreshScan()
        await store.refreshScan()
        #expect(store.events.filter { $0.kind == .loaded }.count == Fixtures.models.count)
        #expect(store.events.filter { $0.kind == .runtimeStarted }.count == Fixtures.runtimes.count)
        await store.refreshScan()
        #expect(store.events.contains { $0.kind == .evicted && $0.text.contains("hermes3:8b") })
        #expect(store.events.contains { $0.kind == .unloaded && $0.text.contains("ggml-large-v3-turbo") })
        #expect(store.events.contains { $0.kind == .runtimeStopped && $0.text.contains("whisper") })
        #expect(store.events.first!.date >= store.events.last!.date)
    }

    @Test func pressureTransitionsAreLogged() async {
        let metrics = SequenceMetrics(snapshots: [Fixtures.quietSystem, Fixtures.system])
        let store = VitalsStore(settings: Fixtures.settings(), metrics: metrics, scanner: StaticScanner(result: .empty))
        await store.refreshMetrics()
        #expect(store.events.isEmpty)
        await store.refreshMetrics()
        #expect(store.events.contains { $0.kind == .pressureWarning })
        #expect(store.events.contains { $0.kind == .thermal })
    }
}

final class SequenceScanner: ModelScanSource {
    private var results: [ScanResult]
    init(results: [ScanResult]) { self.results = results }
    func scan(watched: Set<RuntimeKind>, ports: [RuntimeKind: Int]) async -> ScanResult {
        results.count > 1 ? results.removeFirst() : results[0]
    }
}

final class SequenceMetrics: SystemMetricsSource {
    private var snapshots: [SystemSnapshot]
    init(snapshots: [SystemSnapshot]) { self.snapshots = snapshots }
    func sample() async -> SystemSnapshot {
        snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
    }
}
