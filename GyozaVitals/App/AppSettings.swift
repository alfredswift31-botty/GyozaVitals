import Combine
import Foundation
import ServiceManagement

/// What the status item shows beside the glyph.
nonisolated enum StatusItemContent: String, CaseIterable, Codable, Sendable {
    case iconOnly, modelCount, modelMemory

    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .modelCount: "Number of loaded models"
        case .modelMemory: "Model memory"
        }
    }
}

/// User settings, backed by UserDefaults so tests can use their own suite.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var statusItemContent: StatusItemContent { didSet { save("statusItemContent", statusItemContent.rawValue) } }
    @Published var openMetricsInterval: TimeInterval { didSet { save("openMetricsInterval", openMetricsInterval) } }
    @Published var closedMetricsInterval: TimeInterval { didSet { save("closedMetricsInterval", closedMetricsInterval) } }
    @Published var openScanInterval: TimeInterval { didSet { save("openScanInterval", openScanInterval) } }
    @Published var closedScanInterval: TimeInterval { didSet { save("closedScanInterval", closedScanInterval) } }
    @Published var watchedRuntimes: Set<RuntimeKind> { didSet { save("watchedRuntimes", Array(watchedRuntimes.map(\.rawValue))) } }
    @Published var ports: [RuntimeKind: Int] {
        didSet { save("ports", Dictionary(uniqueKeysWithValues: ports.map { ($0.key.rawValue, $0.value) })) }
    }
    @Published var openAtLogin: Bool { didSet { applyOpenAtLogin() } }

    static let defaultWatched: Set<RuntimeKind> = [.ollama, .llamaServer, .koboldcpp, .lmStudio, .whisper, .comfyUI, .mflux, .sdcpp]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        statusItemContent = StatusItemContent(rawValue: defaults.string(forKey: "statusItemContent") ?? "") ?? .modelMemory
        openMetricsInterval = (defaults.object(forKey: "openMetricsInterval") as? TimeInterval) ?? 2
        closedMetricsInterval = (defaults.object(forKey: "closedMetricsInterval") as? TimeInterval) ?? 15
        openScanInterval = (defaults.object(forKey: "openScanInterval") as? TimeInterval) ?? 5
        closedScanInterval = (defaults.object(forKey: "closedScanInterval") as? TimeInterval) ?? 30
        if let raw = defaults.stringArray(forKey: "watchedRuntimes") {
            watchedRuntimes = Set(raw.compactMap(RuntimeKind.init(rawValue:)))
        } else {
            watchedRuntimes = Self.defaultWatched
        }
        var ports: [RuntimeKind: Int] = [:]
        for kind in RuntimeKind.allCases { if let port = kind.defaultPort { ports[kind] = port } }
        if let saved = defaults.dictionary(forKey: "ports") as? [String: Int] {
            for (key, value) in saved { if let kind = RuntimeKind(rawValue: key) { ports[kind] = value } }
        }
        self.ports = ports
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    private func applyOpenAtLogin() {
        do {
            if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // The system keeps the real state; reflect it rather than the wish.
            let actual = SMAppService.mainApp.status == .enabled
            if actual != openAtLogin { openAtLogin = actual }
        }
    }
}
