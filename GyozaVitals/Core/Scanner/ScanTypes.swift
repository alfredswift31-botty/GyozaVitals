import Foundation

// The scanner's working types: a classified process with what it holds, the
// runtime instance drafted from one or more of them, and what a probe adds.

/// A process the classifier (or the mapped-file check) accepted, with the
/// expensive per-process reads done once.
nonisolated struct AIProcess: Sendable {
    let record: ProcessRecord
    let classification: Classification
    let sockets: [TCPSocket]
    /// Mapped and open weights files, resolved and sized.
    let files: [ModelFile]
    let currentDirectory: String?

    var pid: pid_t { record.pid }
    var kind: RuntimeKind { classification.kind }

    var listeningPorts: [Int] {
        Array(Set(sockets.filter { $0.state == .listening }.map(\.localPort))).sorted()
    }

    /// The first value of any of the argv flags, resolved against the cwd.
    func argumentPath(flags: [String]) -> String? {
        ModelFiles.argumentValue(record.arguments, flags: flags).map { ModelFiles.resolve($0, cwd: currentDirectory) }
    }
}

/// One runtime instance to report, before probing.
nonisolated struct RuntimeDraft: Sendable {
    let kind: RuntimeKind
    /// The process that stands for the runtime: Ollama's server, LM Studio's app.
    let process: AIProcess
    /// Ollama's per-model runners; LM Studio's helpers holding weights.
    let helpers: [AIProcess]
    /// Where to send GETs: the configured port when the process listens on it,
    /// else its first listening port. Nil when it listens nowhere.
    let probePort: Int?

    var pids: Set<pid_t> { Set([process.pid] + helpers.map(\.pid)) }
    var allProcesses: [AIProcess] { [process] + helpers }
    var allListeningPorts: Set<Int> { Set(allProcesses.flatMap(\.listeningPorts)) }
    var footprintBytes: UInt64 { allProcesses.reduce(0) { $0 + $1.record.footprintBytes } }
}

/// What a probe (or the file fallback) found for one draft.
nonisolated struct ProbeResult: Sendable {
    var version: String?
    var isBusy: Bool?
    var models: [LoadedModel]

    static let nothing = ProbeResult(version: nil, isBusy: nil, models: [])
}

/// Weights files for one runtime, unique by resolved path, each with the
/// best-known role: an argv flag beats a guess from the name.
nonisolated struct ModelFileSet: Sendable {
    private var order: [String] = []
    private var files: [String: ModelFile] = [:]
    private var roles: [String: ModelRole] = [:]

    var isEmpty: Bool { order.isEmpty }
    var paths: [String] { order }

    mutating func add(_ file: ModelFile, role: ModelRole? = nil) {
        if files[file.path] == nil {
            order.append(file.path)
            files[file.path] = file
        }
        if let role { roles[file.path] = role }
    }

    mutating func add(contentsOf list: [ModelFile]) {
        for file in list { add(file) }
    }

    /// A path from argv: only when it exists, so a typo never shows as a model.
    mutating func add(path: String?, cwd: String?, role: ModelRole? = nil) {
        guard let path, !path.isEmpty, !path.hasPrefix("-") else { return }
        let resolved = ModelFiles.resolve(path, cwd: cwd)
        guard let size = ModelFiles.size(ofFile: resolved) else { return }
        add(ModelFile(path: resolved, sizeBytes: size), role: role)
    }

    /// Every value of the flags, with the role the flag implies.
    mutating func add(arguments: [String], cwd: String?, flags: [String], role: ModelRole) {
        for value in ModelFiles.argumentValues(arguments, flags: flags) {
            add(path: value, cwd: cwd, role: role)
        }
    }

    func models(runtime: RuntimeKind, pid: pid_t, device: Device, state: ModelState) -> [LoadedModel] {
        order.compactMap { path in
            guard let file = files[path] else { return nil }
            return LoadedModel(
                id: "\(pid):\(path)", name: file.name, filePath: path, runtime: runtime, pid: pid,
                sizeBytes: file.sizeBytes, device: device, contextLength: nil, expiresAt: nil, state: state,
                role: roles[path] ?? ModelRoles.guess(fileName: file.name, runtime: runtime), clients: [], firstSeen: Date())
        }
    }
}

/// Dispatches a draft to its runtime's probe, and to the file fallback when
/// the probe can't run (no port) or runs out of time.
nonisolated enum RuntimeProbes {
    static func inspect(_ draft: RuntimeDraft, client: HTTPClient, ollamaManifests: [String: String]) async -> ProbeResult {
        switch draft.kind {
        case .ollama: return await OllamaProbe.inspect(draft, client: client, manifests: ollamaManifests)
        case .llamaServer: return await LlamaServerProbe.inspect(draft, client: client)
        case .koboldcpp: return await KoboldProbe.inspect(draft, client: client)
        case .lmStudio: return await LMStudioProbe.inspect(draft, client: client)
        case .comfyUI: return await ComfyUIProbe.inspect(draft, client: client)
        case .whisper: return await WhisperProbe.inspect(draft, client: client)
        case .mflux, .sdcpp, .unknown, .appleIntelligence: return FileProbe.offline(draft)
        }
    }

    static func offline(_ draft: RuntimeDraft, ollamaManifests: [String: String]) -> ProbeResult {
        switch draft.kind {
        case .ollama: return OllamaProbe.offline(draft, manifests: ollamaManifests)
        case .llamaServer: return LlamaServerProbe.offline(draft)
        case .koboldcpp: return KoboldProbe.offline(draft)
        case .lmStudio: return LMStudioProbe.offline(draft)
        case .comfyUI: return ComfyUIProbe.offline(draft)
        case .whisper: return WhisperProbe.offline(draft)
        case .mflux, .sdcpp, .unknown, .appleIntelligence: return FileProbe.offline(draft)
        }
    }
}

/// Runtimes with no API: mflux (MLX maps its safetensors), sd.cpp (names its
/// files in argv) and anything unclassified that maps weights.
nonisolated enum FileProbe {
    static func offline(_ draft: RuntimeDraft) -> ProbeResult {
        let process = draft.process
        let arguments = process.record.arguments
        let cwd = process.currentDirectory
        var set = ModelFileSet()
        for member in draft.allProcesses { set.add(contentsOf: member.files) }
        let device: Device
        switch draft.kind {
        case .sdcpp:
            set.add(arguments: arguments, cwd: cwd, flags: ["--model", "-m", "--diffusion-model"], role: .image)
            set.add(arguments: arguments, cwd: cwd, flags: ["--vae"], role: .vae)
            set.add(arguments: arguments, cwd: cwd, flags: ["--clip_l", "--clip_g", "--t5xxl", "--llm", "--clip_vision"], role: .imageEncoder)
            set.add(arguments: arguments, cwd: cwd, flags: ["--upscale-model"], role: .upscaler)
            set.add(arguments: arguments, cwd: cwd, flags: ["--control-net", "--lora-model-dir"], role: .image)
            device = .gpu
        case .mflux:
            device = .gpu
        default:
            device = .unknown
        }
        return ProbeResult(version: nil, isBusy: nil, models: set.models(runtime: draft.kind, pid: process.pid, device: device, state: .idle))
    }
}
