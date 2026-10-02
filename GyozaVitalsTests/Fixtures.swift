import Foundation
@testable import GyozaVitals

/// A realistic afternoon on the owner's Mac: Ollama holding two models,
/// ComfyUI mid-generation, Flow's whisper resident. Used by snapshot tests
/// and previews so every state is designed, not guessed.
@MainActor
enum Fixtures {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let gyozaYap = ClientApp(pid: 501, name: "GyozaYap", bundleIdentifier: "com.gyoza.GyozaYap")
    static let flow = ClientApp(pid: 502, name: "Flow", bundleIdentifier: "com.gyoza.Flow")
    static let bot = ClientApp(pid: 503, name: "python3", bundleIdentifier: nil)
    static let shortcuts = ClientApp(pid: 504, name: "Shortcuts", bundleIdentifier: "com.apple.shortcuts")
    /// A helper process with a long name, as the scanner reported on the owner's Mac.
    static let helper = ClientApp(pid: 505, name: "Qwen Image Networking", bundleIdentifier: nil)

    /// With what the busy heuristic saw, as the Settings diagnostics show it:
    /// Ollama answered its API; ComfyUI's API timed out and the GPU was
    /// credited to it; whisper has no API and only a trickle of CPU.
    static var runtimes: [RuntimeInstance] {
        [
            RuntimeInstance(pid: 900, kind: .ollama, processName: "ollama", executablePath: "/Applications/Ollama.app/Contents/Resources/ollama",
                            listeningPorts: [11434], version: "0.19.2", footprintBytes: 11_200_000_000, isBusy: true, clients: [gyozaYap, flow, bot],
                            diagnostics: BusyDiagnostics(cpuShare: 0.412, gpuUtilization: 0.97, candidate: false, decidedBy: "api"),
                            probeNote: "api answered"),
            RuntimeInstance(pid: 910, kind: .comfyUI, processName: "python3", executablePath: "/Users/me/ComfyUI/.venv/bin/python3",
                            listeningPorts: [8188], version: "0.4.1", footprintBytes: 14_900_000_000, isBusy: true, clients: [],
                            diagnostics: BusyDiagnostics(cpuShare: 0.012, gpuUtilization: 0.97, candidate: true, decidedBy: "gpu"),
                            probeNote: "api timed out, carried over"),
            RuntimeInstance(pid: 920, kind: .whisper, processName: "whisper-stream", executablePath: "/usr/local/bin/whisper-stream",
                            listeningPorts: [], version: nil, footprintBytes: 1_300_000_000, isBusy: false, clients: [],
                            diagnostics: BusyDiagnostics(cpuShare: 0.003, gpuUtilization: 0.97, candidate: false, decidedBy: "none"),
                            probeNote: "no api"),
        ]
    }

    static var models: [LoadedModel] {
        [
            LoadedModel(id: "900:qwen3-vl:8b", name: "huihui_ai/qwen3-vl-abliterated:8b-instruct", filePath: "/Users/me/.ollama/models/blobs/sha256-a1",
                        runtime: .ollama, pid: 900, sizeBytes: 6_550_000_000, device: .gpu, contextLength: 32_768,
                        expiresAt: now.addingTimeInterval(252), state: .executing, role: .vision, clients: [gyozaYap], firstSeen: now.addingTimeInterval(-600)),
            LoadedModel(id: "900:hermes3:8b", name: "hermes3:8b", filePath: "/Users/me/.ollama/models/blobs/sha256-b2",
                        runtime: .ollama, pid: 900, sizeBytes: 4_920_000_000, device: .gpu, contextLength: 8_192,
                        // Four clients: the row shows two and "+2".
                        expiresAt: now.addingTimeInterval(37), state: .idle, role: .text, clients: [gyozaYap, flow, bot, shortcuts],
                        firstSeen: now.addingTimeInterval(-3_000)),
            LoadedModel(id: "910:/Users/me/image-gen/models/qwen-image-2.1-UC-Q4_K_M.gguf", name: "qwen-image-2.1-UC-Q4_K_M.gguf",
                        filePath: "/Users/me/image-gen/models/qwen-image-2.1-UC-Q4_K_M.gguf", runtime: .comfyUI, pid: 910,
                        sizeBytes: 4_600_000_000, device: .gpu, contextLength: nil, expiresAt: nil, state: .executing, role: .image, clients: [],
                        firstSeen: now.addingTimeInterval(-120)),
            LoadedModel(id: "910:/Users/me/image-gen/models/Qwen3VL-8B-Instruct-Q4_K_M.gguf", name: "Qwen3VL-8B-Instruct-Q4_K_M.gguf",
                        filePath: "/Users/me/image-gen/models/Qwen3VL-8B-Instruct-Q4_K_M.gguf", runtime: .comfyUI, pid: 910,
                        sizeBytes: 5_000_000_000, device: .gpu, contextLength: nil, expiresAt: nil, state: .idle, role: .imageEncoder, clients: [],
                        firstSeen: now.addingTimeInterval(-120)),
            LoadedModel(id: "920:/Users/me/.local/share/whisper/ggml-large-v3-turbo-q5_0.bin", name: "ggml-large-v3-turbo-q5_0.bin",
                        filePath: "/Users/me/.local/share/whisper/ggml-large-v3-turbo-q5_0.bin", runtime: .whisper, pid: 920,
                        sizeBytes: 574_000_000, device: .unknown, contextLength: nil, expiresAt: nil, state: .idle, role: .speech, clients: [],
                        firstSeen: now.addingTimeInterval(-7_200)),
        ]
    }

    static var system: SystemSnapshot {
        SystemSnapshot(
            timestamp: now,
            memory: MemorySnapshot(totalBytes: 36 * 1_073_741_824, usedBytes: 31_100_000_000, appBytes: 24_400_000_000,
                                   wiredBytes: 3_200_000_000, compressedBytes: 3_500_000_000, cachedBytes: 2_900_000_000,
                                   swapUsedBytes: 1_200_000_000, swapTotalBytes: 4_000_000_000, pressure: .warning,
                                   modelBytes: 27_400_000_000),
            cpu: CPUSnapshot(total: 0.61, performanceCores: 0.82, efficiencyCores: 0.33, loadAverage: 7.4,
                             performanceCoreCount: 8, efficiencyCoreCount: 4),
            gpu: GPUSnapshot(utilization: 0.97, inUseBytes: 19_300_000_000),
            thermal: .serious,
            power: PowerSnapshot(onBattery: false, batteryPercent: 100, isCharging: false, lowPowerMode: false, minutesToEmpty: nil))
    }

    static var quietSystem: SystemSnapshot {
        var s = system
        s.memory = MemorySnapshot(totalBytes: 36 * 1_073_741_824, usedBytes: 12_000_000_000, appBytes: 7_900_000_000,
                                  wiredBytes: 2_600_000_000, compressedBytes: 1_500_000_000, cachedBytes: 6_100_000_000,
                                  swapUsedBytes: 0, swapTotalBytes: 0, pressure: .normal, modelBytes: 0)
        s.cpu = CPUSnapshot(total: 0.04, performanceCores: 0.01, efficiencyCores: 0.09, loadAverage: 1.2,
                            performanceCoreCount: 8, efficiencyCoreCount: 4)
        s.gpu = GPUSnapshot(utilization: 0.02, inUseBytes: 900_000_000)
        s.thermal = .nominal
        s.power = PowerSnapshot(onBattery: true, batteryPercent: 64, isCharging: false, lowPowerMode: true, minutesToEmpty: 312)
        return s
    }

    static var events: [ActivityEvent] {
        [
            ActivityEvent(date: now.addingTimeInterval(-120), kind: .loaded, text: "qwen-image-2.1-UC-Q4_K_M.gguf loaded in ComfyUI"),
            ActivityEvent(date: now.addingTimeInterval(-125), kind: .pressureWarning, text: "memory pressure warning"),
            ActivityEvent(date: now.addingTimeInterval(-600), kind: .loaded, text: "huihui_ai/qwen3-vl-abliterated:8b-instruct loaded in ollama"),
            ActivityEvent(date: now.addingTimeInterval(-610), kind: .evicted, text: "hermes3:3b evicted from ollama"),
            ActivityEvent(date: now.addingTimeInterval(-7_200), kind: .runtimeStarted, text: "whisper.cpp started"),
        ]
    }

    static func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "fixtures-\(UUID().uuidString)")!)
    }

    static func busyStore() -> VitalsStore {
        VitalsStore(settings: settings(), system: system, runtimes: runtimes, models: models, events: events, appleIntelligenceAvailable: true)
    }

    static func quietStore() -> VitalsStore {
        VitalsStore(settings: settings(), system: quietSystem, runtimes: [], models: [], events: [], appleIntelligenceAvailable: true)
    }

    // MARK: The bad minute: pressure critical, one model executing, one loading, one on its way out

    static var criticalSystem: SystemSnapshot {
        var s = system
        s.memory = MemorySnapshot(totalBytes: 36 * 1_073_741_824, usedBytes: 37_900_000_000, appBytes: 27_100_000_000,
                                  wiredBytes: 4_100_000_000, compressedBytes: 6_700_000_000, cachedBytes: 400_000_000,
                                  swapUsedBytes: 5_800_000_000, swapTotalBytes: 8_000_000_000, pressure: .critical,
                                  modelBytes: 31_600_000_000)
        s.cpu = CPUSnapshot(total: 0.88, performanceCores: 0.99, efficiencyCores: 0.61, loadAverage: 14.2,
                            performanceCoreCount: 8, efficiencyCoreCount: 4)
        s.gpu = GPUSnapshot(utilization: 1.0, inUseBytes: 24_800_000_000)
        s.thermal = .critical
        s.power = PowerSnapshot(onBattery: false, batteryPercent: 100, isCharging: true, lowPowerMode: false, minutesToEmpty: nil)
        return s
    }

    static var criticalModels: [LoadedModel] {
        [
            LoadedModel(id: "900:qwen3-vl:8b", name: "huihui_ai/qwen3-vl-abliterated:8b-instruct", filePath: nil,
                        runtime: .ollama, pid: 900, sizeBytes: 6_550_000_000, device: .gpu, contextLength: 32_768,
                        expiresAt: now.addingTimeInterval(252), state: .executing, role: .vision, clients: [gyozaYap], firstSeen: now.addingTimeInterval(-600)),
            LoadedModel(id: "900:gemma3:27b", name: "gemma3:27b", filePath: nil,
                        runtime: .ollama, pid: 900, sizeBytes: 17_400_000_000, device: .split, contextLength: 8_192,
                        // Long helper names truncate at the tail; "loading" on the right must survive.
                        expiresAt: nil, state: .loading, role: .text, clients: [helper, helper, flow], firstSeen: now),
            LoadedModel(id: "900:hermes3:8b", name: "hermes3:8b", filePath: nil,
                        runtime: .ollama, pid: 900, sizeBytes: 4_920_000_000, device: .gpu, contextLength: 8_192,
                        expiresAt: now.addingTimeInterval(2), state: .unloading, role: .text, clients: [], firstSeen: now.addingTimeInterval(-3_000)),
            LoadedModel(id: "910:/Users/me/image-gen/models/qwen-image-2.1-UC-Q4_K_M.gguf", name: "qwen-image-2.1-UC-Q4_K_M.gguf",
                        filePath: "/Users/me/image-gen/models/qwen-image-2.1-UC-Q4_K_M.gguf", runtime: .comfyUI, pid: 910,
                        sizeBytes: 4_600_000_000, device: .gpu, contextLength: nil, expiresAt: nil, state: .executing, role: .image, clients: [],
                        firstSeen: now.addingTimeInterval(-120)),
        ]
    }

    static var criticalEvents: [ActivityEvent] {
        [
            ActivityEvent(date: now.addingTimeInterval(-4), kind: .pressureCritical, text: "memory pressure critical"),
            ActivityEvent(date: now.addingTimeInterval(-9), kind: .thermal, text: "thermal state critical"),
            ActivityEvent(date: now.addingTimeInterval(-15), kind: .loaded, text: "gemma3:27b loaded in ollama"),
            ActivityEvent(date: now.addingTimeInterval(-125), kind: .pressureWarning, text: "memory pressure warning"),
            ActivityEvent(date: now.addingTimeInterval(-610), kind: .evicted, text: "hermes3:3b evicted from ollama"),
            ActivityEvent(date: now.addingTimeInterval(-7_200), kind: .runtimeStarted, text: "whisper.cpp started"),
        ]
    }

    static func criticalStore() -> VitalsStore {
        var busy = Self.runtimes
        busy[0].footprintBytes = 29_700_000_000
        return VitalsStore(settings: settings(), system: criticalSystem, runtimes: busy, models: criticalModels,
                           events: criticalEvents, appleIntelligenceAvailable: false)
    }

    // MARK: One model, nobody connected, no GPU figures from the OS, on battery

    static var singleSystem: SystemSnapshot {
        var s = quietSystem
        s.memory.modelBytes = 1_300_000_000
        s.memory.usedBytes = 13_300_000_000
        s.memory.appBytes = 9_200_000_000
        s.gpu = nil
        s.power = PowerSnapshot(onBattery: true, batteryPercent: 38, isCharging: true, lowPowerMode: false, minutesToEmpty: 141)
        return s
    }

    static func singleStore() -> VitalsStore {
        let runtime = runtimes[2]
        let model = models[4]
        return VitalsStore(settings: settings(), system: singleSystem, runtimes: [runtime], models: [model],
                           events: [ActivityEvent(date: now.addingTimeInterval(-7_200), kind: .runtimeStarted, text: "whisper.cpp started")],
                           appleIntelligenceAvailable: nil)
    }

    // MARK: What the memory meta line covers across the stores
    //
    // busyStore: models 27.4 GB · swap 1.2 GB (swap > 0)
    // criticalStore: models 29.7 GB (+) · swap 5.8 GB
    // singleStore: models 1.3 GB, swap 0 (no "· swap")
    // quietStore: models 0, swap 0 ("no model memory")

    // MARK: Pressure history for the strip, oldest first

    static var busyPressure: [MemoryPressure?] {
        [MemoryPressure?](repeating: .normal, count: 38) + [MemoryPressure?](repeating: .warning, count: 21)
    }

    static var criticalPressure: [MemoryPressure?] {
        let warm = [MemoryPressure?](repeating: .normal, count: 20) + [MemoryPressure?](repeating: .warning, count: 30)
        return warm + [MemoryPressure?](repeating: .critical, count: 9)
    }

    static var quietPressure: [MemoryPressure?] {
        [MemoryPressure?](repeating: .normal, count: 59)
    }
}
