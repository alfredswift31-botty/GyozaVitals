import AppKit
import Darwin
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The live `ModelScanSource`: processes → classification → files, sockets
/// and footprint for the AI ones → runtime probes → client attribution.
/// The work runs on `ScanPipeline`, an actor off the main thread; this
/// class only remembers first-seen dates and resolves the client apps.
final class ModelScanner: ModelScanSource {
    private let pipeline = ScanPipeline()
    private var firstSeen: [String: Date] = [:]
    private var stickyClients = StickyClients()
    /// The system GPU utilisation the store last measured (0...1), for the
    /// busy heuristic of runtimes with no API. Nil: unknown, CPU rule only.
    var gpuUtilization: Double?

    init() {}

    func noteSystemGPU(utilization: Double?) {
        gpuUtilization = utilization
    }

    func scan(watched: Set<RuntimeKind>, ports: [RuntimeKind: Int]) async -> ScanResult {
        let output = await pipeline.run(watched: watched, ports: ports, gpuUtilization: gpuUtilization)
        var result = output.result
        let now = Date()
        var remembered: [String: Date] = [:]
        var resolver = ClientResolver(chains: output.clientChains)
        var byRuntime: [pid_t: [ClientApp]] = [:]
        result.runtimes = result.runtimes.map { runtime in
            var runtime = runtime
            // A runtime's own app isn't its client: Ollama.app launches `ollama serve`.
            let own = runtime.kind.displayName.lowercased()
            let seen = resolver.resolve(runtime.clients).filter { !$0.name.lowercased().contains(own) }
            runtime.clients = stickyClients.update(pid: runtime.pid, seen: seen, now: now)
            byRuntime[runtime.pid] = runtime.clients
            return runtime
        }
        stickyClients.forget(except: Set(result.runtimes.map(\.pid)))
        result.models = result.models.map { model in
            var model = model
            let date = firstSeen[model.id] ?? now
            remembered[model.id] = date
            model.firstSeen = date
            model.clients = byRuntime[model.pid] ?? resolver.resolve(model.clients)
            return model
        }
        firstSeen = remembered
        result.appleIntelligenceAvailable = Self.appleIntelligenceAvailability()
        return result
    }

    /// FoundationModels is weak-linked (it is newer than the deployment
    /// target), so this is nil on macOS 15 and wherever the SDK can't say.
    private static func appleIntelligenceAvailability() -> Bool? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return true
            case .unavailable: return false
            @unknown default: return nil
            }
        }
        #endif
        return nil
    }
}

/// Turns the pipeline's connecting processes into the apps that own them:
/// each link of a parent chain is looked up in NSRunningApplication (its
/// localized name and bundle identifier), the chain is resolved, and the
/// results are deduped per app. Main actor, since NSRunningApplication is.
struct ClientResolver {
    private let chains: [pid_t: [ProcessChainLink]]
    private var resolved: [pid_t: ResolvedClient] = [:]

    init(chains: [pid_t: [ProcessChainLink]]) {
        self.chains = chains
    }

    mutating func resolve(_ clients: [ClientApp]) -> [ClientApp] {
        ClientFinder.dedupe(clients.map { resolve($0) })
    }

    mutating func resolve(_ client: ClientApp) -> ResolvedClient {
        if let known = resolved[client.pid] { return known }
        let chain = (chains[client.pid] ?? [ProcessChainLink(pid: client.pid, name: client.name, executablePath: nil)]).map(Self.named)
        let result = ClientFinder.resolveApp(chain: chain)
            ?? ResolvedClient(app: ClientApp(pid: client.pid, name: client.name, bundleIdentifier: nil), isHelper: false)
        resolved[client.pid] = result
        return result
    }

    /// The app's own name and bundle id when the pid is an app; the kernel's
    /// executable name otherwise.
    static func named(_ link: ProcessChainLink) -> ProcessChainLink {
        guard let app = NSRunningApplication(processIdentifier: link.pid) else { return link }
        var link = link
        if let name = app.localizedName, !name.isEmpty { link.name = name }
        link.bundleIdentifier = app.bundleIdentifier ?? link.bundleIdentifier
        return link
    }
}

/// One scan, start to finish, off the main actor.
actor ScanPipeline {
    private let client = HTTPClient()
    private let pollerCatcher = PollerCatcher()
    private var manifestNames: [String: String] = [:]
    private var manifestRoots: [String] = []
    private var manifestsBuiltAt = Date.distantPast
    private var cpuActivity = CPUActivity()
    /// What the APIs said last scan, by model id, for a scan where they don't answer.
    private var apiModels: [String: LoadedModel] = [:]
    /// Last scan's busy verdict per runtime: the burst decision is made
    /// before this scan's probes have answered.
    private var lastBusy: [pid_t: Bool] = [:]
    /// When each runtime was last watched for pollers.
    private var lastBurst: [pid_t: Date] = [:]

    /// Each probe gets this long (its GETs time out at `HTTPClient.defaultTimeout`
    /// and run concurrently); the file fallback answers for a slower one.
    static let probeDeadline: Double = HTTPClient.defaultTimeout + 1
    /// Below this a process can't hold a model worth a region walk.
    static let genericFootprintFloor: UInt64 = 256 * 1_048_576
    /// A mapped weights file this large makes an unclassified process a runtime.
    static let genericModelFloor: UInt64 = 100 * 1_048_576
    /// ...unless its name says upscaler: Real-ESRGAN x4plus is 64 MB.
    static let upscalerModelFloor: UInt64 = 32 * 1_048_576
    /// Weights a classified runtime holds can be small (a projector, a tiny whisper).
    static let classifiedModelFloor: UInt64 = 8 * 1_048_576
    static let genericCandidateLimit = 40
    /// A process younger than this may still be loading its model.
    static let youngProcessSeconds: TimeInterval = 20
    /// How long a runtime is watched for pollers, concurrently with the probes.
    static let burstDuration: TimeInterval = 1.2
    /// A runtime is watched at most this often: a catch stays sticky for
    /// `StickyClients.memory`, twice this.
    static let burstCooldown: TimeInterval = 30

    func run(watched: Set<RuntimeKind>, ports: [RuntimeKind: Int], gpuUtilization: Double? = nil) async -> PipelineOutput {
        let selfPID = getpid()
        let sampledAt = ProcessInfo.processInfo.systemUptime
        let processes = ProcessList.currentUserProcesses()
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        // Classify, then read files and sockets for the AI processes only.
        var aiProcesses: [AIProcess] = []
        for process in processes where process.pid != selfPID {
            guard let classification = ProcessClassifier.classify(process, parent: byPID[process.parentPID]) else { continue }
            aiProcesses.append(Self.inspect(process, classification: classification))
        }
        aiProcesses += Self.genericProcesses(among: processes, excluding: Set(aiProcesses.map(\.pid)).union([selfPID]))

        let drafts = Self.drafts(from: aiProcesses, watched: watched, ports: ports)
        let manifests = await ollamaManifests(for: drafts)
        let cpuDeltas = cpuActivity.observe(drafts.flatMap { $0.allProcesses.map(\.record) }, at: sampledAt)

        // Who is connected to which port, before the probes: the burst
        // decision needs it.
        let allPorts = Set(drafts.flatMap { $0.allListeningPorts })
        let connections = ClientFinder.connections(to: allPorts, among: processes)

        // A busy runtime that no connection or launcher names is driven by
        // something this scan can't see: watch for its pollers while the
        // probes run. Last scan's verdict stands in for this scan's, which
        // the probes haven't given yet; a quarter of a core now counts too.
        let now = Date()
        var burstPorts = Set<Int>()
        for draft in drafts {
            let pid = draft.process.pid
            var scratch: [pid_t: [ProcessChainLink]] = [:]
            let visible = Self.attribution(for: draft, connections: connections, processes: byPID, pollers: [],
                                           excluding: draft.pids.union([selfPID]), chains: &scratch)
            let busy = lastBusy[pid] == true || CPUActivity.busy(deltas: draft.pids.compactMap { cpuDeltas[$0] }) == true
            guard Self.shouldBurst(ports: draft.allListeningPorts, hasClient: visible.hasClient, isBusy: busy,
                                   lastBurst: lastBurst[pid], now: now) else { continue }
            lastBurst[pid] = now
            burstPorts.formUnion(draft.allListeningPorts)
        }
        let catcher = pollerCatcher
        let known = Set(processes.map(\.pid))
        let portsToWatch = burstPorts
        async let burst = catcher.catchPollers(ports: portsToWatch, among: known, processes: byPID, duration: Self.burstDuration)

        // Probe every draft at once, each within its deadline.
        let client = self.client
        let results = await withTaskGroup(of: (pid_t, ProbeResult).self, returning: [pid_t: ProbeResult].self) { group in
            for draft in drafts {
                group.addTask {
                    let probed = await withDeadline(seconds: Self.probeDeadline) {
                        await RuntimeProbes.inspect(draft, client: client, ollamaManifests: manifests)
                    }
                    return (draft.process.pid, probed ?? RuntimeProbes.offline(draft, ollamaManifests: manifests))
                }
            }
            var results: [pid_t: ProbeResult] = [:]
            for await (pid, result) in group { results[pid] = result }
            return results
        }

        let pollers = Self.pollers(await burst, for: drafts)
        let output = Self.assemble(drafts: drafts, results: results, manifests: manifests, connections: connections,
                                   processes: byPID, cpuDeltas: cpuDeltas, selfPID: selfPID, pollers: pollers,
                                   gpuUtilization: gpuUtilization, previous: apiModels, now: Date())
        apiModels = output.apiModels
        let live = Set(output.result.runtimes.map(\.pid))
        lastBusy = Dictionary(output.result.runtimes.map { ($0.pid, $0.isBusy ?? false) }, uniquingKeysWith: { first, _ in first })
        lastBurst = lastBurst.filter { live.contains($0.key) }
        return output
    }

    /// Whether to spend a burst on a runtime: it listens somewhere (a), no
    /// connection or launcher names a client (b), it is busy (c): polls
    /// happen during a generation, and it hasn't been watched within
    /// `burstCooldown` (d): the main actor keeps a catch sticky for a minute.
    static func shouldBurst(ports: Set<Int>, hasClient: Bool, isBusy: Bool, lastBurst: Date?, now: Date) -> Bool {
        guard !ports.isEmpty, !hasClient, isBusy else { return false }
        if let lastBurst, now.timeIntervalSince(lastBurst) < burstCooldown { return false }
        return true
    }

    /// Caught pollers by the pid of the runtime whose port they connected to.
    static func pollers(_ caught: [CaughtPoller], for drafts: [RuntimeDraft]) -> [pid_t: [CaughtPoller]] {
        var result: [pid_t: [CaughtPoller]] = [:]
        for poller in caught {
            for draft in drafts where draft.allListeningPorts.contains(poller.port) {
                result[draft.process.pid, default: []].append(poller)
            }
        }
        return result
    }

    /// Runtimes and models from what was found, pure: drafts, what their
    /// probes said, who connects to their ports, how much CPU they used
    /// since the last scan, the pollers caught per runtime pid, the system
    /// GPU, and what the APIs said last time (`previous`, by model id) for a
    /// probe that didn't answer now.
    static func assemble(drafts: [RuntimeDraft], results: [pid_t: ProbeResult], manifests: [String: String],
                         connections: [Int: [ProcessRecord]], processes byPID: [pid_t: ProcessRecord],
                         cpuDeltas: [pid_t: CPUActivity.Delta], selfPID: pid_t, pollers: [pid_t: [CaughtPoller]] = [:],
                         gpuUtilization: Double? = nil, previous: [String: LoadedModel] = [:], now: Date = Date()) -> PipelineOutput {
        var runtimes: [RuntimeInstance] = []
        var models: [LoadedModel] = []
        var chains: [pid_t: [ProcessChainLink]] = [:]
        var apiModels: [String: LoadedModel] = [:]

        // The probe's models, or the fallback's with last scan's API fields
        // carried over, before anything is counted.
        var probes: [pid_t: ProbeResult] = [:]
        var resident: [pid_t: [LoadedModel]] = [:]
        for draft in drafts {
            let probe = results[draft.process.pid] ?? RuntimeProbes.offline(draft, ollamaManifests: manifests)
            probes[draft.process.pid] = probe
            resident[draft.process.pid] = probe.apiAnswered ? probe.models : carryOver(probe.models, in: draft, previous: previous, now: now)
        }
        // The heuristic's inputs, before anything is decided: each runtime's
        // CPU share, and which of those without an API answer could be
        // credited with the GPU (see CPUActivity.gpuCredit).
        var shares: [pid_t: Double?] = [:]
        var candidates: [pid_t: Double?] = [:]
        for draft in drafts {
            let pid = draft.process.pid
            shares[pid] = CPUActivity.share(deltas: draft.pids.compactMap { cpuDeltas[$0] })
            if probes[pid]?.isBusy == nil, isGPUCandidate(kind: draft.kind, models: resident[pid] ?? []) {
                candidates.updateValue(shares[pid] ?? nil, forKey: pid)
            }
        }
        let credited = CPUActivity.gpuCredit(gpuUtilization: gpuUtilization, candidates: candidates)

        for draft in drafts {
            let pid = draft.process.pid
            let probe = probes[pid] ?? .nothing
            let attribution = Self.attribution(for: draft, connections: connections, processes: byPID, pollers: pollers[pid] ?? [],
                                               excluding: draft.pids.union([selfPID]), chains: &chains)
            let clients = attribution.clients
            let share = shares[pid] ?? nil
            let candidate = candidates[pid] != nil

            // No answer from an API: the CPU/GPU heuristic decides, and a busy
            // runtime's resident models are executing. Loading stays loading.
            var isBusy = probe.isBusy
            var decidedBy = "api"
            var probedModels = resident[pid] ?? []
            if isBusy == nil {
                let verdict = CPUActivity.verdict(cpuShare: share, gpuUtilization: gpuUtilization, gpuCredited: credited == pid)
                isBusy = verdict.isBusy
                decidedBy = verdict.decidedBy
                if isBusy == true {
                    probedModels = probedModels.map { model in
                        var model = model
                        if model.state == .idle { model.state = .executing }
                        return model
                    }
                }
            }
            for model in probedModels where probe.apiAnswered || previous[model.id] != nil {
                apiModels[model.id] = model
            }

            runtimes.append(RuntimeInstance(
                pid: pid, kind: draft.kind, processName: draft.process.record.name,
                executablePath: draft.process.record.executablePath, listeningPorts: draft.process.listeningPorts,
                version: probe.version, footprintBytes: draft.footprintBytes, isBusy: isBusy, clients: clients,
                diagnostics: BusyDiagnostics(cpuShare: share, gpuUtilization: gpuUtilization, candidate: candidate, decidedBy: decidedBy),
                probeNote: probeNote(for: draft, probe: probe, previous: previous), attributionNote: attribution.note))
            models += probedModels.map { model in
                var model = model
                model.clients = clients
                return model
            }
        }
        runtimes.sort { ($0.kind.rawValue, $0.pid) < ($1.kind.rawValue, $1.pid) }
        models.sort { ($0.runtime.rawValue, $0.pid, $0.name) < ($1.runtime.rawValue, $1.pid, $1.name) }
        return PipelineOutput(result: ScanResult(runtimes: runtimes, models: models, appleIntelligenceAvailable: nil),
                              clientChains: chains, apiModels: apiModels)
    }

    /// A runtime the busy GPU could belong to: one that holds weights on the
    /// GPU (or split), or an image runtime whatever its files say (sd.cpp,
    /// mflux, ComfyUI, an unclassified process holding an upscaler). A
    /// whisper whose model device is unknown is not one: it holds nothing
    /// the GPU would be working on, and the CPU rule still covers it.
    static func isGPUCandidate(kind: RuntimeKind, models: [LoadedModel]) -> Bool {
        if models.contains(where: { $0.device == .gpu || $0.device == .split }) { return true }
        switch kind {
        case .sdcpp, .mflux, .comfyUI: return true
        case .unknown: return models.contains { $0.role == .upscaler }
        case .ollama, .llamaServer, .koboldcpp, .lmStudio, .whisper, .appleIntelligence: return false
        }
    }

    /// One phrase on how the probe went, for the diagnostics pane.
    static func probeNote(for draft: RuntimeDraft, probe: ProbeResult, previous: [String: LoadedModel]) -> String {
        if probe.apiAnswered { return "api answered" }
        switch draft.kind {
        case .sdcpp, .mflux, .unknown, .appleIntelligence, .whisper: return "no api"
        case .ollama, .llamaServer, .koboldcpp, .lmStudio, .comfyUI: break
        }
        guard draft.probePort != nil else { return "no port" }
        let pid = draft.process.pid
        return previous.values.contains { $0.pid == pid } ? "api timed out, carried over" : "api timed out"
    }

    // MARK: Carry-over

    /// The fallback's models with what the API said about them last time,
    /// for a probe that timed out or failed while its process is still
    /// here: the API's name (and so the id), device, context, role and
    /// unload time survive a slow answer instead of flipping to the file's.
    /// The state is never `.loading` unless the process holding the model is
    /// younger than `youngProcessSeconds`: an older one that stopped
    /// answering is busy or idle, which the heuristic then decides.
    static func carryOver(_ models: [LoadedModel], in draft: RuntimeDraft, previous: [String: LoadedModel], now: Date) -> [LoadedModel] {
        guard !models.isEmpty else { return models }
        let byPath = Dictionary(previous.values.filter { $0.pid == draft.process.pid }.compactMap { model in model.filePath.map { ($0, model) } },
                                uniquingKeysWith: { first, _ in first })
        return models.map { model in
            let young = age(of: model, in: draft, now: now) < youngProcessSeconds
            var state = model.state
            if state == .loading, !young { state = .idle }
            guard let remembered = previous[model.id] ?? model.filePath.flatMap({ byPath[$0] }) else {
                var model = model
                model.state = state
                return model
            }
            return LoadedModel(
                id: remembered.id, name: remembered.name, filePath: model.filePath ?? remembered.filePath, runtime: model.runtime,
                pid: model.pid, sizeBytes: remembered.sizeBytes > 0 ? remembered.sizeBytes : model.sizeBytes,
                device: remembered.device != .unknown ? remembered.device : model.device,
                contextLength: model.contextLength ?? remembered.contextLength,
                expiresAt: remembered.expiresAt.flatMap { $0 > now ? $0 : nil },
                state: state, role: remembered.role, clients: [], firstSeen: model.firstSeen)
        }
    }

    /// How long the process that holds the model has been running: the
    /// youngest of the draft's processes that map or name its file, else
    /// the runtime's main process. Ollama's runner, not its server.
    static func age(of model: LoadedModel, in draft: RuntimeDraft, now: Date) -> TimeInterval {
        var start = draft.process.record.startTime
        if let path = model.filePath {
            let holders = draft.allProcesses.filter { process in
                process.files.contains { $0.path == path } || process.argumentPath(flags: ["--model", "-m"]) == path
            }
            if let youngest = holders.map(\.record.startTime).max() { start = youngest }
        }
        return now.timeIntervalSince1970 - TimeInterval(start)
    }

    // MARK: Processes

    private static func inspect(_ process: ProcessRecord, classification: Classification) -> AIProcess {
        let pid = process.pid
        let paths = ProcessFiles.mappedFiles(pid: pid) + ProcessFiles.openFiles(pid: pid)
        return AIProcess(
            record: process, classification: classification, sockets: ProcessFiles.sockets(pid: pid),
            files: ModelFiles.files(amongPaths: paths, minimumBytes: classifiedModelFloor),
            currentDirectory: ProcessFiles.currentDirectory(pid: pid))
    }

    /// Unclassified processes that map a large weights file: a tool we don't
    /// know yet still shows up, as `.unknown`. Only the heavy ones are walked.
    private static func genericProcesses(among processes: [ProcessRecord], excluding: Set<pid_t>) -> [AIProcess] {
        let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]
        let candidates = processes
            .filter { process in
                !excluding.contains(process.pid) && process.footprintBytes >= genericFootprintFloor
                    && !systemPrefixes.contains { process.executablePath?.hasPrefix($0) ?? false }
            }
            .sorted { $0.footprintBytes > $1.footprintBytes }
            .prefix(genericCandidateLimit)
        return candidates.compactMap { process in
            let files = ModelFiles.files(amongPaths: ProcessFiles.mappedFiles(pid: process.pid), minimumBytes: genericModelFloor,
                                         upscalerMinimumBytes: upscalerModelFloor)
            guard !files.isEmpty else { return nil }
            return AIProcess(record: process, classification: Classification(.unknown), sockets: ProcessFiles.sockets(pid: process.pid),
                             files: files, currentDirectory: nil)
        }
    }

    // MARK: Drafts

    /// Ollama's runners fold into their server; LM Studio's helpers into the
    /// app; everything else is one runtime per process.
    static func drafts(from aiProcesses: [AIProcess], watched: Set<RuntimeKind>, ports: [RuntimeKind: Int]) -> [RuntimeDraft] {
        var drafts: [RuntimeDraft] = []

        let servers = aiProcesses.filter { $0.kind == .ollama && !$0.classification.isOllamaRunner }
        var runners = aiProcesses.filter { $0.kind == .ollama && $0.classification.isOllamaRunner }
        for server in servers {
            var mine = runners.filter { $0.record.parentPID == server.pid }
            if mine.isEmpty, servers.count == 1 { mine = runners }
            runners.removeAll { runner in mine.contains { $0.pid == runner.pid } }
            let preferred = [ports[.ollama], ollamaHostPort()].compactMap { $0 }
            drafts.append(RuntimeDraft(kind: .ollama, process: server, helpers: mine, probePort: probePort(server, preferred: preferred)))
        }
        for runner in runners {
            // A runner whose server we can't see: it still holds the model.
            drafts.append(RuntimeDraft(kind: .ollama, process: runner, helpers: [], probePort: nil))
        }

        let lmStudio = aiProcesses.filter { $0.kind == .lmStudio }
        if !lmStudio.isEmpty {
            let preferred = [ports[.lmStudio] ?? RuntimeKind.lmStudio.defaultPort].compactMap { $0 }
            let primary = lmStudio.first { process in preferred.contains { process.listeningPorts.contains($0) } }
                ?? lmStudio.first { !$0.listeningPorts.isEmpty }
                ?? lmStudio.first { $0.record.name == "LM Studio" }
                ?? lmStudio.sorted { $0.record.footprintBytes > $1.record.footprintBytes }[0]
            let helpers = lmStudio.filter { $0.pid != primary.pid && !$0.files.isEmpty }
            let port = probePort(primary, preferred: preferred) ?? helpers.lazy.compactMap { probePort($0, preferred: preferred) }.first ?? preferred.first
            drafts.append(RuntimeDraft(kind: .lmStudio, process: primary, helpers: helpers, probePort: port))
        }

        for process in aiProcesses where process.kind != .ollama && process.kind != .lmStudio {
            let preferred = [ports[process.kind] ?? process.kind.defaultPort].compactMap { $0 }
            drafts.append(RuntimeDraft(kind: process.kind, process: process, helpers: [], probePort: probePort(process, preferred: preferred)))
        }

        return drafts.filter { $0.kind == .unknown || watched.contains($0.kind) }
    }

    /// The configured port when the process listens on it; otherwise the
    /// first port it listens on. Two runtimes on "8080" are told apart here.
    private static func probePort(_ process: AIProcess, preferred: [Int]) -> Int? {
        let listening = process.listeningPorts
        return preferred.first { listening.contains($0) } ?? listening.first
    }

    /// $OLLAMA_HOST in the app's own environment, when set to "host:port".
    private static func ollamaHostPort() -> Int? {
        guard let host = ProcessInfo.processInfo.environment["OLLAMA_HOST"], let colon = host.lastIndex(of: ":") else { return nil }
        return Int(host[host.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    // MARK: Clients

    /// One runtime's clients and where they came from, for the diagnostics.
    nonisolated struct Attribution: Sendable {
        var clients: [ClientApp] = []
        /// Processes with a connection open at the scan instant.
        var connected = 0
        /// The process that launched the runtime counts.
        var launcher = false
        /// Short-lived processes the burst caught connecting.
        var caught = 0

        var hasClient: Bool { !clients.isEmpty }

        /// "2 connected, launcher, caught 1 poller", or "no client seen".
        var note: String {
            var parts: [String] = []
            if connected > 0 { parts.append("\(connected) connected") }
            if launcher { parts.append("launcher") }
            if caught > 0 { parts.append("caught \(caught) \(caught == 1 ? "poller" : "pollers")") }
            return parts.isEmpty ? "no client seen" : parts.joined(separator: ", ")
        }
    }

    /// The connecting processes, as executable names; the main actor resolves
    /// them to apps through their parent chains, which are recorded here. A
    /// process whose chain passes through the runtime itself is its child,
    /// not a client (Ollama talking to its runner, a server's own worker).
    /// Three sources: connections open now, the runtime's launcher, and the
    /// pollers a burst caught (see `PollerCatcher`), each once per pid.
    static func attribution(for draft: RuntimeDraft, connections: [Int: [ProcessRecord]], processes byPID: [pid_t: ProcessRecord],
                            pollers: [CaughtPoller], excluding: Set<pid_t>, chains: inout [pid_t: [ProcessChainLink]]) -> Attribution {
        var seen = Set<pid_t>()
        var clients: [ClientApp] = []
        var attribution = Attribution()
        for port in draft.allListeningPorts.sorted() {
            for process in connections[port] ?? [] where !excluding.contains(process.pid) && seen.insert(process.pid).inserted {
                let chain = chains[process.pid] ?? ClientFinder.chain(from: process, among: byPID)
                guard !ClientFinder.chain(chain, passesThrough: excluding) else { continue }
                chains[process.pid] = chain
                clients.append(ClientFinder.client(for: process))
                attribution.connected += 1
            }
        }
        // The process that launched the runtime uses it too, and that fact
        // holds on every scan. An app that spawns sd-server and polls it with
        // short requests is between polls when most scans land, so a socket
        // may never be caught; its parent chain is always there. A shell or
        // launchd as the parent is a boundary and names nobody.
        if let parent = byPID[draft.process.record.parentPID], parent.pid > 1,
           !excluding.contains(parent.pid), seen.insert(parent.pid).inserted {
            let chain = chains[parent.pid] ?? ClientFinder.chain(from: parent, among: byPID)
            if let first = chain.first, !ClientFinder.isBoundary(first) {
                chains[parent.pid] = chain
                clients.append(ClientFinder.client(for: parent))
                attribution.launcher = true
            }
        }
        // A poller caught mid-request is a connecting process that happened
        // to live for milliseconds: same chain rules, same resolution.
        for poller in pollers where !excluding.contains(poller.pid) && seen.insert(poller.pid).inserted {
            let chain = poller.chain.isEmpty
                ? [ProcessChainLink(pid: poller.pid, name: poller.name, executablePath: poller.executablePath)] : poller.chain
            guard !ClientFinder.chain(chain, passesThrough: excluding) else { continue }
            chains[poller.pid] = chain
            clients.append(ClientApp(pid: poller.pid, name: poller.name, bundleIdentifier: nil))
            attribution.caught += 1
        }
        attribution.clients = clients.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return attribution
    }

    // MARK: Ollama manifests

    /// Digest → name, rebuilt at most once a minute and only while a runner exists.
    private func ollamaManifests(for drafts: [RuntimeDraft]) async -> [String: String] {
        let runners = drafts.filter { $0.kind == .ollama }.flatMap { draft in
            draft.process.classification.isOllamaRunner ? [draft.process] : draft.helpers
        }
        guard !runners.isEmpty else { return manifestNames }
        let blobs = runners.compactMap { $0.argumentPath(flags: ["--model", "-m"]) }
        let roots = OllamaManifests.roots(blobPaths: blobs)
        if roots != manifestRoots || Date().timeIntervalSince(manifestsBuiltAt) > 60 {
            manifestNames = OllamaManifests.names(roots: roots)
            manifestRoots = roots
            manifestsBuiltAt = Date()
        }
        return manifestNames
    }
}

/// Clients a runtime was seen with recently. A scan only sees connections
/// open at that instant; an app that drives its runtime with short polling
/// requests (start the job, then ask for progress every second) is usually
/// between polls when the scan lands. The owner's Qwen Image app showed as
/// the client on some scans and vanished on others for exactly that reason.
/// So a runtime keeps its last non-empty client list for `memory` seconds.
nonisolated struct StickyClients {
    static let memory: TimeInterval = 60

    private var last: [pid_t: (clients: [ClientApp], seen: Date)] = [:]

    /// The clients to show for this runtime: what was seen now, or what was
    /// seen within the last minute.
    mutating func update(pid: pid_t, seen: [ClientApp], now: Date) -> [ClientApp] {
        if !seen.isEmpty {
            last[pid] = (seen, now)
            return seen
        }
        if let remembered = last[pid], now.timeIntervalSince(remembered.seen) <= Self.memory {
            return remembered.clients
        }
        last[pid] = nil
        return []
    }

    /// Drop runtimes that are gone, so a reused pid can't inherit clients.
    mutating func forget(except live: Set<pid_t>) {
        last = last.filter { live.contains($0.key) }
    }
}
