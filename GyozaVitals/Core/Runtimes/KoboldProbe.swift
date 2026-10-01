import Foundation

// koboldcpp: GET /api/extra/version (identity, version, vision), /api/v1/model
// (the loaded model's name), /api/extra/perf (idle, queue, speed) and
// /api/extra/true_max_context_length. Files come from argv; kobold also maps
// its GGUF, so the two are merged by path.

nonisolated struct KoboldVersion: Hashable, Sendable {
    let version: String
    let hasVision: Bool
}

nonisolated struct KoboldPerf: Hashable, Sendable {
    let idle: Bool
    let queue: Int
    let lastEvalSpeed: Double?
}

nonisolated enum KoboldProbe {
    // MARK: Parsing

    static func parseVersion(_ data: Data?) -> KoboldVersion? {
        guard let object = JSON.object(data), JSON.string(object["result"]) == "KoboldCpp",
              let version = JSON.string(object["version"]) else { return nil }
        return KoboldVersion(version: version, hasVision: JSON.bool(object["vision"]) ?? false)
    }

    static func parseModelName(_ data: Data?) -> String? {
        guard let name = JSON.string(JSON.object(data)?["result"]), !name.isEmpty else { return nil }
        return name.hasPrefix("koboldcpp/") ? String(name.dropFirst("koboldcpp/".count)) : name
    }

    static func parsePerf(_ data: Data?) -> KoboldPerf? {
        guard let object = JSON.object(data), object["idle"] != nil else { return nil }
        let idle = JSON.int(object["idle"]).map { $0 != 0 } ?? JSON.bool(object["idle"]) ?? true
        return KoboldPerf(idle: idle, queue: JSON.int(object["queue"]) ?? 0, lastEvalSpeed: JSON.double(object["last_eval_speed"]))
    }

    static func parseMaxContext(_ data: Data?) -> Int? {
        JSON.int(JSON.object(data)?["value"])
    }

    // MARK: Probe

    static func inspect(_ draft: RuntimeDraft, client: HTTPClient) async -> ProbeResult {
        guard let port = draft.probePort else { return offline(draft) }
        async let versionData = client.getData(port: port, path: "/api/extra/version")
        async let modelData = client.getData(port: port, path: "/api/v1/model")
        async let perfData = client.getData(port: port, path: "/api/extra/perf")
        async let contextData = client.getData(port: port, path: "/api/extra/true_max_context_length")
        let version = parseVersion(await versionData)
        let modelName = parseModelName(await modelData)
        let perf = parsePerf(await perfData)
        let maxContext = parseMaxContext(await contextData)
        return assemble(draft, version: version, modelName: modelName, perf: perf, maxContext: maxContext)
    }

    static func offline(_ draft: RuntimeDraft) -> ProbeResult {
        assemble(draft, version: nil, modelName: nil, perf: nil, maxContext: nil)
    }

    static func assemble(_ draft: RuntimeDraft, version: KoboldVersion?, modelName: String?, perf: KoboldPerf?, maxContext: Int?) -> ProbeResult {
        let process = draft.process
        let arguments = process.record.arguments
        let cwd = process.currentDirectory
        var set = ModelFileSet()
        set.add(contentsOf: process.files)
        set.add(arguments: arguments, cwd: cwd, flags: ["--model", "-m"], role: .text)
        set.add(arguments: arguments, cwd: cwd, flags: ["--mmproj"], role: .projector)
        set.add(arguments: arguments, cwd: cwd, flags: ["--draftmodel"], role: .text)
        set.add(arguments: arguments, cwd: cwd, flags: ["--sdmodel"], role: .image)
        set.add(arguments: arguments, cwd: cwd, flags: ["--sdvae"], role: .vae)
        set.add(arguments: arguments, cwd: cwd, flags: ["--sdt5xxl", "--sdclipl", "--sdclipg"], role: .imageEncoder)
        set.add(arguments: arguments, cwd: cwd, flags: ["--whispermodel"], role: .speech)
        set.add(arguments: arguments, cwd: cwd, flags: ["--ttsmodel", "--ttswavtokenizer"], role: .speech)
        set.add(arguments: arguments, cwd: cwd, flags: ["--embeddingsmodel"], role: .embedding)
        // A positional model: `koboldcpp model.gguf`, or `python koboldcpp.py model.gguf`.
        if let positional = positionalModel(arguments) { set.add(path: positional, cwd: cwd, role: .text) }

        let isBusy: Bool? = perf.map { !$0.idle }
        let state: ModelState = isBusy == true ? .executing : .idle
        let device: Device = arguments.contains("--usecpu") || ModelFiles.flagIsZero(arguments, flags: ["--gpulayers"]) ? .cpu : .gpu
        var models = set.models(runtime: .koboldcpp, pid: process.pid, device: device, state: state)
        if let index = models.firstIndex(where: { $0.role == .text }) ?? models.indices.first {
            models[index].contextLength = maxContext
            if let modelName, !modelName.isEmpty, modelName != "protected-model" { models[index].name = modelName }
        }
        return ProbeResult(version: version?.version, isBusy: isBusy, models: models)
    }

    /// The first bare argument that names a weights file and isn't the value
    /// of a flag ("--model x.gguf" is handled by the flag; "--usecpu x.gguf"
    /// is missed here but the mapped file still shows up).
    static func positionalModel(_ arguments: [String]) -> String? {
        for index in 1..<max(1, arguments.count) {
            let argument = arguments[index]
            guard !argument.hasPrefix("-"), !argument.hasSuffix("koboldcpp.py"), ModelFiles.isModelPath(argument) else { continue }
            if arguments[index - 1].hasPrefix("-") { continue }
            return argument
        }
        return nil
    }
}
