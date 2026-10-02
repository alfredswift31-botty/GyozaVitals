import Foundation

// The shared vocabulary of GyozaVitals. Every source (process scanner,
// runtime probes, system metrics) produces these; the UI reads only these.
// Value types are nonisolated so they can cross from background scanning
// to the main-actor store.

/// A local inference runtime the app knows how to recognise.
nonisolated enum RuntimeKind: String, Codable, CaseIterable, Sendable {
    case ollama, llamaServer, koboldcpp, lmStudio, whisper, comfyUI, mflux, sdcpp, appleIntelligence, unknown

    var displayName: String {
        switch self {
        case .ollama: "ollama"
        case .llamaServer: "llama-server"
        case .koboldcpp: "koboldcpp"
        case .lmStudio: "LM Studio"
        case .whisper: "whisper.cpp"
        case .comfyUI: "ComfyUI"
        case .mflux: "mflux"
        case .sdcpp: "sd.cpp"
        case .appleIntelligence: "Apple Intelligence"
        case .unknown: "unknown"
        }
    }

    /// The port the runtime listens on unless configured otherwise.
    var defaultPort: Int? {
        switch self {
        case .ollama: 11434
        case .llamaServer: 8080
        case .koboldcpp: 5001
        case .lmStudio: 1234
        case .comfyUI: 8188
        case .whisper: 8080
        case .mflux, .sdcpp, .appleIntelligence, .unknown: nil
        }
    }
}

/// A running process that hosts models.
nonisolated struct RuntimeInstance: Identifiable, Hashable, Sendable {
    var id: pid_t { pid }
    let pid: pid_t
    let kind: RuntimeKind
    /// Executable name, e.g. "llama-server".
    let processName: String
    let executablePath: String?
    /// Ports this process listens on (loopback).
    var listeningPorts: [Int]
    var version: String?
    /// Physical footprint, what Activity Monitor calls Memory.
    var footprintBytes: UInt64
    /// True while the runtime is serving a request, when it can tell us.
    var isBusy: Bool?
    /// Processes connected to this runtime's ports.
    var clients: [ClientApp]
}

/// What a model file is for, guessed from its name and the runtime.
nonisolated enum ModelRole: String, Codable, Sendable {
    case text, vision, embedding, reranker, speech, image, imageEncoder, vae, upscaler, projector, unknown
}

nonisolated enum ModelState: String, Codable, Sendable {
    case loading, idle, executing, unloading
}

nonisolated enum Device: String, Codable, Sendable {
    case gpu, cpu, split, unknown
}

/// A model that is resident in memory right now.
nonisolated struct LoadedModel: Identifiable, Hashable, Sendable {
    /// Stable across refreshes: "<pid>:<file path or API name>".
    let id: String
    var name: String
    var filePath: String?
    var runtime: RuntimeKind
    var pid: pid_t
    /// File size, or the runtime's reported size.
    var sizeBytes: UInt64
    var device: Device
    var contextLength: Int?
    /// When the runtime will unload it, if it says (Ollama's expires_at).
    var expiresAt: Date?
    var state: ModelState
    var role: ModelRole
    var clients: [ClientApp]
    var firstSeen: Date
}

/// An app or tool connected to a runtime.
nonisolated struct ClientApp: Identifiable, Hashable, Sendable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
}

// MARK: - System

nonisolated enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical
}

nonisolated struct MemorySnapshot: Hashable, Sendable {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var cachedBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64
    var pressure: MemoryPressure
    /// Sum of the runtimes' footprints.
    var modelBytes: UInt64

    var freeBytes: UInt64 { totalBytes > usedBytes ? totalBytes - usedBytes : 0 }

    /// How much more could be loaded before pressure: free plus cached,
    /// minus a 10 % reserve. Only meaningful while pressure is normal.
    var headroomBytes: UInt64? {
        guard pressure == .normal else { return nil }
        let reserve = totalBytes / 10
        let available = freeBytes + cachedBytes
        return available > reserve ? available - reserve : 0
    }
}

nonisolated struct CPUSnapshot: Hashable, Sendable {
    /// 0...1, smoothed.
    var total: Double
    var performanceCores: Double?
    var efficiencyCores: Double?
    var loadAverage: Double
    var performanceCoreCount: Int
    var efficiencyCoreCount: Int
}

nonisolated struct GPUSnapshot: Hashable, Sendable {
    /// 0...1, smoothed. Nil when the OS doesn't report it.
    var utilization: Double?
    var inUseBytes: UInt64?
}

nonisolated enum ThermalLevel: String, Codable, Sendable {
    case nominal, fair, serious, critical
}

nonisolated struct PowerSnapshot: Hashable, Sendable {
    var onBattery: Bool
    var batteryPercent: Int?
    var isCharging: Bool
    var lowPowerMode: Bool
    var minutesToEmpty: Int?
}

nonisolated struct SystemSnapshot: Hashable, Sendable {
    var timestamp: Date
    var memory: MemorySnapshot
    var cpu: CPUSnapshot
    var gpu: GPUSnapshot?
    var thermal: ThermalLevel
    var power: PowerSnapshot
}

// MARK: - Activity

nonisolated enum ActivityKind: String, Codable, Sendable {
    case loaded, unloaded, evicted, runtimeStarted, runtimeStopped, pressureWarning, pressureCritical, thermal
}

nonisolated struct ActivityEvent: Identifiable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let kind: ActivityKind
    /// One line, e.g. "qwen3-vl:8b loaded in ollama".
    let text: String

    init(id: UUID = UUID(), date: Date = Date(), kind: ActivityKind, text: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.text = text
    }
}

/// One pass over processes and runtime APIs.
nonisolated struct ScanResult: Sendable {
    var runtimes: [RuntimeInstance]
    var models: [LoadedModel]
    /// Apple Intelligence availability, when the SDK can say; nil = unknown.
    var appleIntelligenceAvailable: Bool?

    static let empty = ScanResult(runtimes: [], models: [], appleIntelligenceAvailable: nil)
}

// MARK: - Sources

/// Reads the machine. Implemented by SystemMetrics; faked by tests.
protocol SystemMetricsSource: AnyObject {
    func sample() async -> SystemSnapshot
}

/// Finds runtimes and models. Implemented by the process scanner plus
/// runtime probes; faked by tests.
protocol ModelScanSource: AnyObject {
    func scan(watched: Set<RuntimeKind>, ports: [RuntimeKind: Int]) async -> ScanResult
    /// The latest system GPU utilisation (0...1, nil when the OS doesn't
    /// report it), handed over before each scan so the busy heuristic can
    /// use it. Optional: the default does nothing.
    func noteSystemGPU(utilization: Double?)
}

extension ModelScanSource {
    func noteSystemGPU(utilization: Double?) {}
}
