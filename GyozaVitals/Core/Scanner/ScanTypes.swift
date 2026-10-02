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
    /// True when the runtime's own API described its models. False for the
    /// file fallback, a probe that timed out, or a runtime with no API: the
    /// pipeline then carries over what the API said last time.
    var apiAnswered: Bool = false

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

// MARK: - CPU-time heuristic

/// Whether a runtime with no API to ask is working, from its CPU time and
/// the system GPU: a process using more than a quarter of one core, averaged
/// over the scan interval, is executing. Metal-bound generation (sd.cpp at
/// 96 % GPU) can stay well under that on the CPU, so a second rule credits
/// the GPU to a runtime when the GPU is busy (≥ 80 %), the runtime shows at
/// least a trickle of CPU (≥ 3 % of a core: a process encoding command
/// buffers is never fully asleep), and it is the only GPU-using runtime
/// whose busy state the APIs can't give. The last condition is the
/// false-positive guard: with Real-ESRGAN upscaling in another process at
/// 100 % GPU while sd.cpp sat idle, two candidates share the GPU and neither
/// is credited; the CPU rule alone decides for both.
///
/// Samples are kept per (pid, start time) across scans; the first scan of a
/// process answers nil. Only `isBusy == nil` from a probe is replaced.
nonisolated struct CPUActivity: Sendable {
    nonisolated struct Key: Hashable, Sendable {
        let pid: pid_t
        let startTime: UInt64
    }

    nonisolated struct Sample: Hashable, Sendable {
        let cpuSeconds: Double
        let uptime: TimeInterval
    }

    nonisolated struct Delta: Hashable, Sendable {
        let cpuSeconds: Double
        let wallSeconds: Double
    }

    /// Above this share of one core the process counts as busy.
    static let busyCoreFraction = 0.25
    /// Below this many seconds between samples the ratio is noise.
    static let minimumInterval = 0.05
    /// The system GPU is busy at or above this utilisation.
    static let busyGPUFraction = 0.8
    /// A GPU-bound runtime still shows at least this share of a core; below
    /// it the GPU belongs to something that holds no model (a game, a video).
    static let gpuCompanionCoreFraction = 0.03

    private var samples: [Key: Sample] = [:]

    init() {}

    /// The share of one core, or nil when the interval is too short to say
    /// or the counter went backwards.
    static func share(cpuDelta: Double, wallDelta: Double) -> Double? {
        guard wallDelta >= minimumInterval, cpuDelta.isFinite, cpuDelta >= 0 else { return nil }
        return cpuDelta / wallDelta
    }

    /// A group of processes (a runtime and its helpers): their CPU time
    /// added up over the longest interval any of them has. Nil when none has
    /// a previous sample.
    static func share(deltas: [Delta]) -> Double? {
        guard !deltas.isEmpty else { return nil }
        let cpu = deltas.reduce(0) { $0 + $1.cpuSeconds }
        let wall = deltas.map(\.wallSeconds).max() ?? 0
        return share(cpuDelta: cpu, wallDelta: wall)
    }

    /// Busy, idle, or unknown when the interval is too short to say.
    static func busy(cpuDelta: Double, wallDelta: Double) -> Bool? {
        busy(cpuShare: share(cpuDelta: cpuDelta, wallDelta: wallDelta), gpuUtilization: nil, gpuCandidates: 0)
    }

    /// The verdict for a group of processes, CPU time alone.
    static func busy(deltas: [Delta]) -> Bool? {
        busy(cpuShare: share(deltas: deltas), gpuUtilization: nil, gpuCandidates: 0)
    }

    /// The combined rule. `cpuShare` is the runtime's share of one core since
    /// the last scan (nil: no sample yet, so unknown). `gpuUtilization` is the
    /// system's (nil when the OS doesn't report it). `gpuCandidates` counts
    /// the runtimes that use the GPU and whose busy state no API gave, this
    /// one included; the GPU is credited only when it is the single one.
    ///
    ///   busy = cpuShare > 0.25
    ///       || (gpu ≥ 0.8 && cpuShare ≥ 0.03 && gpuCandidates == 1)
    static func busy(cpuShare: Double?, gpuUtilization: Double?, gpuCandidates: Int) -> Bool? {
        guard let cpuShare else { return nil }
        if cpuShare > busyCoreFraction { return true }
        if let gpuUtilization, gpuUtilization >= busyGPUFraction, cpuShare >= gpuCompanionCoreFraction, gpuCandidates == 1 {
            return true
        }
        return false
    }

    /// Records this scan's readings and returns, per pid, the change since
    /// the previous scan for the processes that were seen then with the same
    /// start time. Processes not in `records` are forgotten.
    mutating func observe(_ records: [ProcessRecord], at uptime: TimeInterval) -> [pid_t: Delta] {
        var next: [Key: Sample] = [:]
        var deltas: [pid_t: Delta] = [:]
        for record in records {
            let key = Key(pid: record.pid, startTime: record.startTime)
            let sample = Sample(cpuSeconds: record.cpuSeconds, uptime: uptime)
            if let previous = samples[key] {
                deltas[record.pid] = Delta(cpuSeconds: sample.cpuSeconds - previous.cpuSeconds, wallSeconds: uptime - previous.uptime)
            }
            next[key] = sample
        }
        samples = next
        return deltas
    }
}

/// What one pass of the pipeline hands the main actor: the result, plus the
/// parent chain of every connecting process so the apps can be resolved
/// where NSRunningApplication may be asked.
nonisolated struct PipelineOutput: Sendable {
    var result: ScanResult
    var clientChains: [pid_t: [ProcessChainLink]]
    /// Models whose fields came from a runtime API this scan (or were carried
    /// over from one), by id: next scan's fallback when that API is slow.
    var apiModels: [String: LoadedModel] = [:]
}
