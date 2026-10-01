import Foundation

/// Where the real sources are wired up. The scaffold ships static stand-ins
/// so the app builds; the metrics and scanner modules replace these.
enum LiveSources {
    static func metrics() -> SystemMetricsSource { StaticMetrics(snapshot: nil) }
    static func scanner() -> ModelScanSource { StaticScanner(result: .empty) }
}
