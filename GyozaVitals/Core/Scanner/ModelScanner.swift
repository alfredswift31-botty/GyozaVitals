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

    init() {}

    func scan(watched: Set<RuntimeKind>, ports: [RuntimeKind: Int]) async -> ScanResult {
        let output = await pipeline.run(watched: watched, ports: ports)
        var result = output.result
        let now = Date()
        var remembered: [String: Date] = [:]
        var resolver = ClientResolver(chains: output.clientChains)
        var byRuntime: [pid_t: [ClientApp]] = [:]
        result.runtimes = result.runtimes.map { runtime in
            var runtime = runtime
            runtime.clients = resolver.resolve(runtime.clients)
            byRuntime[runtime.pid] = runtime.clients
            return runtime
        }
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
    private let client = HTTPClient(timeout: 1.5)
    private var manifestNames: [String: String] = [:]
    private var manifestRoots: [String] = []
    private var manifestsBuiltAt = Date.distantPast
    private var cpuActivity = CPUActivity()

    /// Each probe gets this long; the file fallback answers for a slow one.
    static let probeDeadline: Double = 2.6
    /// Below this a process can't hold a model worth a region walk.
    static let genericFootprintFloor: UInt64 = 256 * 1_048_576
    /// A mapped weights file this large makes an unclassified process a runtime.
    static let genericModelFloor: UInt64 = 100 * 1_048_576
    /// Weights a classified runtime holds can be small (a projector, a tiny whisper).
    static let classifiedModelFloor: UInt64 = 8 * 1_048_576
    static let genericCandidateLimit = 40

    func run(watched: Set<RuntimeKind>, ports: [RuntimeKind: Int]) async -> PipelineOutput {
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

        // Who is connected to which port.
        let allPorts = Set(drafts.flatMap { $0.allListeningPorts })
        let connections = ClientFinder.connections(to: allPorts, among: processes)

        return Self.assemble(drafts: drafts, results: results, manifests: manifests, connections: connections,
                             processes: byPID, cpuDeltas: cpuDeltas, selfPID: selfPID)
    }

    /// Runtimes and models from what was found, pure: drafts, what their
    /// probes said, who connects to their ports, and how much CPU they used
    /// since the last scan.
    static func assemble(drafts: [RuntimeDraft], results: [pid_t: ProbeResult], manifests: [String: String],
                         connections: [Int: [ProcessRecord]], processes byPID: [pid_t: ProcessRecord],
                         cpuDeltas: [pid_t: CPUActivity.Delta], selfPID: pid_t) -> PipelineOutput {
        var runtimes: [RuntimeInstance] = []
        var models: [LoadedModel] = []
        var chains: [pid_t: [ProcessChainLink]] = [:]
        for draft in drafts {
            let probe = results[draft.process.pid] ?? RuntimeProbes.offline(draft, ollamaManifests: manifests)
            let clients = Self.clients(for: draft, connections: connections, processes: byPID,
                                       excluding: draft.pids.union([selfPID]), chains: &chains)

            // No answer from an API: the CPU-time heuristic decides, and a busy
            // runtime's resident models are executing. Loading stays loading.
            var isBusy = probe.isBusy
            var probedModels = probe.models
            if isBusy == nil {
                isBusy = CPUActivity.busy(deltas: draft.pids.compactMap { cpuDeltas[$0] })
                if isBusy == true {
                    probedModels = probedModels.map { model in
                        var model = model
                        if model.state == .idle { model.state = .executing }
                        return model
                    }
                }
            }

            runtimes.append(RuntimeInstance(
                pid: draft.process.pid, kind: draft.kind, processName: draft.process.record.name,
                executablePath: draft.process.record.executablePath, listeningPorts: draft.process.listeningPorts,
                version: probe.version, footprintBytes: draft.footprintBytes, isBusy: isBusy, clients: clients))
            models += probedModels.map { model in
                var model = model
                model.clients = clients
                return model
            }
        }
        runtimes.sort { ($0.kind.rawValue, $0.pid) < ($1.kind.rawValue, $1.pid) }
        models.sort { ($0.runtime.rawValue, $0.pid, $0.name) < ($1.runtime.rawValue, $1.pid, $1.name) }
        return PipelineOutput(result: ScanResult(runtimes: runtimes, models: models, appleIntelligenceAvailable: nil), clientChains: chains)
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
            let files = ModelFiles.files(amongPaths: ProcessFiles.mappedFiles(pid: process.pid), minimumBytes: genericModelFloor)
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

    /// The connecting processes, as executable names; the main actor resolves
    /// them to apps through their parent chains, which are recorded here. A
    /// process whose chain passes through the runtime itself is its child,
    /// not a client (Ollama talking to its runner, a server's own worker).
    private static func clients(for draft: RuntimeDraft, connections: [Int: [ProcessRecord]], processes byPID: [pid_t: ProcessRecord],
                                excluding: Set<pid_t>, chains: inout [pid_t: [ProcessChainLink]]) -> [ClientApp] {
        var seen = Set<pid_t>()
        var clients: [ClientApp] = []
        for port in draft.allListeningPorts.sorted() {
            for process in connections[port] ?? [] where !excluding.contains(process.pid) && seen.insert(process.pid).inserted {
                let chain = chains[process.pid] ?? ClientFinder.chain(from: process, among: byPID)
                guard !ClientFinder.chain(chain, passesThrough: excluding) else { continue }
                chains[process.pid] = chain
                clients.append(ClientFinder.client(for: process))
            }
        }
        return clients.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
