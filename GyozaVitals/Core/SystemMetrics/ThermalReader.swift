import Foundation

/// `ProcessInfo.thermalState`, mapped onto the app's vocabulary.
nonisolated struct ThermalReader: Sendable {
    static func read() -> ThermalLevel {
        level(for: ProcessInfo.processInfo.thermalState)
    }

    static func level(for state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}
