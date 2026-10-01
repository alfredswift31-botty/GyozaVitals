import Foundation

// Ollama: GET /api/version and /api/ps on the server, then /slots and /props
// on the llama-server runner it spawned for each model. When the API is off
// (or a model is still loading), the runner's --model blob is mapped back to
// a name through ~/.ollama/models/manifests.

/// One entry of GET /api/ps.
nonisolated struct OllamaPSModel: Hashable, Sendable {
    let name: String
    let model: String
    let sizeBytes: UInt64
    let vramBytes: UInt64
    let digest: String?
    let families: [String]
    let expiresAt: Date?
    let contextLength: Int?

    /// Where the weights live: all in VRAM, none, or part.
    var device: Device {
        if vramBytes == 0 { return .cpu }
        return vramBytes >= sizeBytes ? .gpu : .split
    }

    /// "sha256:<hex>" → "<hex>"; the blob file is named "sha256-<hex>".
    var digestHex: String? { digest.flatMap(OllamaProbe.hex(fromDigest:)) }
}

/// A runner process with what its own endpoints said.
nonisolated struct OllamaRunner: Sendable {
    let process: AIProcess
    let blobPath: String?
    let blobHex: String?
    let port: Int?
    var isProcessing: Bool?
    var contextLength: Int?
}

nonisolated enum OllamaProbe {
    // MARK: Parsing

    static func parseVersion(_ data: Data?) -> String? {
        JSON.string(JSON.object(data)?["version"])
    }

    static func parsePS(_ data: Data?) -> [OllamaPSModel]? {
        guard let object = JSON.object(data), let list = object["models"] as? [Any] else { return nil }
        return list.compactMap { entry -> OllamaPSModel? in
            guard let item = entry as? [String: Any] else { return nil }
            let name = JSON.string(item["name"]) ?? JSON.string(item["model"]) ?? ""
            guard !name.isEmpty else { return nil }
            let details = item["details"] as? [String: Any]
            return OllamaPSModel(
                name: name,
                model: JSON.string(item["model"]) ?? name,
                sizeBytes: JSON.uint64(item["size"]) ?? 0,
                vramBytes: JSON.uint64(item["size_vram"]) ?? 0,
                digest: JSON.string(item["digest"]),
                families: JSON.strings(details?["families"]),
                expiresAt: JSON.string(item["expires_at"]).flatMap(RFC3339.date),
                contextLength: JSON.int(item["context_length"]))
        }
    }

    static func hex(fromDigest digest: String) -> String? {
        guard let separator = digest.firstIndex(where: { $0 == ":" || $0 == "-" }) else { return nil }
        let hex = digest[digest.index(after: separator)...]
        return hex.isEmpty ? nil : String(hex)
    }

    static func hex(fromBlobPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("sha256-") else { return nil }
        return hex(fromDigest: name)
    }

    // MARK: Runners

    static func runners(in draft: RuntimeDraft) -> [OllamaRunner] {
        let processes = draft.process.classification.isOllamaRunner ? [draft.process] : draft.helpers
        return processes.map { process in
            let arguments = process.record.arguments
            let blob = ModelFiles.argumentValue(arguments, flags: ["--model", "-m"]).map { ModelFiles.resolve($0, cwd: process.currentDirectory) }
            let port = process.listeningPorts.first ?? ModelFiles.argumentValue(arguments, flags: ["--port"]).flatMap { Int($0) }
            return OllamaRunner(process: process, blobPath: blob, blobHex: blob.flatMap(hex(fromBlobPath:)), port: port,
                                isProcessing: nil, contextLength: nil)
        }
    }

    private static func ask(_ runner: OllamaRunner, client: HTTPClient) async -> OllamaRunner {
        guard let port = runner.port else { return runner }
        async let slotsData = client.getData(port: port, path: "/slots")
        async let propsData = client.getData(port: port, path: "/props")
        let slots = LlamaServerProbe.parseSlots(await slotsData)
        let props = LlamaServerProbe.parseProps(await propsData)
        var result = runner
        if let slots {
            result.isProcessing = slots.contains { $0.isProcessing }
            result.contextLength = slots.first?.contextLength
        }
        if result.contextLength == nil, let props, let perSlot = props.contextPerSlot { result.contextLength = perSlot }
        return result
    }

    // MARK: Probe

    static func inspect(_ draft: RuntimeDraft, client: HTTPClient, manifests: [String: String]) async -> ProbeResult {
        let isServer = !draft.process.classification.isOllamaRunner
        let port = isServer ? draft.probePort : nil
        async let versionData = client.getDataIfPort(port, path: "/api/version")
        async let psData = client.getDataIfPort(port, path: "/api/ps")

        let asked = await withTaskGroup(of: OllamaRunner.self, returning: [OllamaRunner].self) { group in
            for runner in runners(in: draft) {
                group.addTask { await ask(runner, client: client) }
            }
            var list: [OllamaRunner] = []
            for await runner in group { list.append(runner) }
            return list.sorted { $0.process.pid < $1.process.pid }
        }
        let version = parseVersion(await versionData)
        let ps = parsePS(await psData)
        return assemble(draft: draft, version: version, ps: ps, runners: asked, manifests: manifests)
    }

    static func offline(_ draft: RuntimeDraft, manifests: [String: String]) -> ProbeResult {
        assemble(draft: draft, version: nil, ps: nil, runners: runners(in: draft), manifests: manifests)
    }

    static func assemble(draft: RuntimeDraft, version: String?, ps: [OllamaPSModel]?, runners: [OllamaRunner],
                         manifests: [String: String]) -> ProbeResult {
        let pid = draft.process.pid
        var models: [LoadedModel] = []
        var matched = Set<pid_t>()
        for entry in ps ?? [] {
            let runner = runners.first { $0.blobHex != nil && $0.blobHex == entry.digestHex }
            if let runner { matched.insert(runner.process.pid) }
            let size = entry.sizeBytes > 0 ? entry.sizeBytes : (runner?.blobPath.flatMap(ModelFiles.size(ofFile:)) ?? 0)
            models.append(LoadedModel(
                id: "\(pid):\(entry.name)", name: entry.name, filePath: runner?.blobPath, runtime: .ollama, pid: pid,
                sizeBytes: size, device: entry.device, contextLength: runner?.contextLength ?? entry.contextLength,
                expiresAt: entry.expiresAt, state: runner?.isProcessing == true ? .executing : .idle,
                role: ModelRoles.guess(ollamaName: entry.name, families: entry.families), clients: [], firstSeen: Date()))
        }
        // Runners the API didn't list: still loading, or the API is off.
        for runner in runners where !matched.contains(runner.process.pid) {
            let name = runner.blobHex.flatMap { manifests[$0] }
                ?? runner.blobPath.map { ($0 as NSString).lastPathComponent }
                ?? "ollama model"
            let size = runner.blobPath.flatMap(ModelFiles.size(ofFile:)) ?? runner.process.files.reduce(0) { $0 + $1.sizeBytes }
            let state: ModelState = ps != nil ? .loading : (runner.isProcessing == true ? .executing : .idle)
            let device: Device = ModelFiles.flagIsZero(runner.process.record.arguments, flags: ["-ngl", "--n-gpu-layers", "--gpu-layers"]) ? .cpu : .gpu
            models.append(LoadedModel(
                id: "\(pid):\(name)", name: name, filePath: runner.blobPath, runtime: .ollama, pid: pid,
                sizeBytes: size, device: device, contextLength: runner.contextLength, expiresAt: nil, state: state,
                role: ModelRoles.guess(fileName: name, runtime: .ollama), clients: [], firstSeen: Date()))
        }
        let answered = runners.compactMap(\.isProcessing)
        let isBusy: Bool? = answered.isEmpty ? nil : answered.contains(true)
        return ProbeResult(version: version, isBusy: isBusy, models: models)
    }
}

/// Ollama's manifest store: maps a model blob's digest back to "repo:tag".
nonisolated enum OllamaManifests {
    /// Where the models live: next to the runners' blobs, $OLLAMA_MODELS, or
    /// the default, in that order of trust.
    static func roots(blobPaths: [String]) -> [String] {
        var roots: [String] = []
        for blob in blobPaths {
            let blobsDirectory = (blob as NSString).deletingLastPathComponent
            guard (blobsDirectory as NSString).lastPathComponent == "blobs" else { continue }
            roots.append((blobsDirectory as NSString).deletingLastPathComponent)
        }
        if let env = ProcessInfo.processInfo.environment["OLLAMA_MODELS"], !env.isEmpty {
            roots.append((env as NSString).expandingTildeInPath)
        }
        roots.append((NSHomeDirectory() as NSString).appendingPathComponent(".ollama/models"))
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }

    /// Digest hex → model name, for every manifest under the roots.
    static func names(roots: [String], maximumFiles: Int = 4_000) -> [String: String] {
        var names: [String: String] = [:]
        let manager = FileManager.default
        var budget = maximumFiles
        for root in roots {
            let manifests = (root as NSString).appendingPathComponent("manifests")
            guard let enumerator = manager.enumerator(atPath: manifests) else { continue }
            while let relative = enumerator.nextObject() as? String {
                guard budget > 0 else { return names }
                let components = relative.split(separator: "/").map(String.init)
                guard components.count >= 3, !components.contains(where: { $0.hasPrefix(".") }) else { continue }
                let path = (manifests as NSString).appendingPathComponent(relative)
                guard let size = ModelFiles.size(ofFile: path), size < 1_000_000 else { continue }
                budget -= 1
                guard let data = manager.contents(atPath: path), let name = name(forComponents: components) else { continue }
                for hex in modelDigests(inManifest: data) where names[hex] == nil {
                    names[hex] = name
                }
            }
        }
        return names
    }

    /// The hex digests of the "image.model" layers (the weights themselves).
    static func modelDigests(inManifest data: Data) -> [String] {
        guard let object = JSON.object(data) else { return [] }
        return JSON.objects(object["layers"]).compactMap { layer in
            guard let mediaType = JSON.string(layer["mediaType"]), mediaType.contains("image.model"),
                  let digest = JSON.string(layer["digest"]) else { return nil }
            return OllamaProbe.hex(fromDigest: digest)
        }
    }

    /// [registry, namespace, repo, tag] → "namespace/repo:tag", dropping the
    /// default registry and the "library" namespace, keeping "hf.co/...".
    static func name(forComponents components: [String]) -> String? {
        guard components.count >= 3 else { return nil }
        let tag = components[components.count - 1]
        let repo = components[components.count - 2]
        var prefix = Array(components[0..<(components.count - 2)])
        if prefix.first == "registry.ollama.ai" { prefix.removeFirst() }
        if prefix.first == "library" { prefix.removeFirst() }
        let head = (prefix + [repo]).joined(separator: "/")
        return "\(head):\(tag)"
    }
}
