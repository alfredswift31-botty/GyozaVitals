import Foundation

/// Where the real sources are wired up.
enum LiveSources {
    static func metrics() -> SystemMetricsSource { SystemMetrics() }
    static func scanner() -> ModelScanSource { ModelScanner() }
}
