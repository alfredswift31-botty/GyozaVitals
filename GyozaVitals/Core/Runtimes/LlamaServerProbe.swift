import Foundation

// llama-server: GET /props (model path, slots, build), /slots (what each slot
// is doing), /health (loading or ready). Router mode (`llama-server` with a
// model directory, GET /models) is handled best effort and unverified: its
// children are ordinary llama-server processes and show up on their own.

nonisolated struct LlamaSlot: Hashable, Sendable {
    let id: Int
    let isProcessing: Bool
    let contextLength: Int?
}

nonisolated struct LlamaProps: Hashable, Sendable {
    let modelPath: String?
    let totalSlots: Int?
    let buildInfo: String?
    let hasVision: Bool?
    let isSleeping: Bool?
    /// The default settings' n_ctx: the context each slot gets.
    let contextPerSlot: Int?
}

nonisolated enum LlamaServerProbe {
    // MARK: Parsing

    static func parseSlots(_ data: Data?) -> [LlamaSlot]? {
        guard let list = JSON.array(data) else { return nil }
        return list.compactMap { entry in
            guard let slot = entry as? [String: Any] else { return nil }
            return LlamaSlot(id: JSON.int(slot["id"]) ?? 0, isProcessing: JSON.bool(slot["is_processing"]) ?? false,
                             contextLength: JSON.int(slot["n_ctx"]))
        }
    }

    static func parseProps(_ data: Data?) -> LlamaProps? {
        guard let object = JSON.object(data) else { return nil }
        // Some other service answering /props with JSON is not llama-server.
        guard object["model_path"] != nil || object["total_slots"] != nil || object["default_generation_settings"] != nil else { return nil }
        let defaults = object["default_generation_settings"] as? [String: Any]
        let modalities = object["modalities"] as? [String: Any]
        return LlamaProps(
            modelPath: JSON.string(object["model_path"]),
            totalSlots: JSON.int(object["total_slots"]),
            buildInfo: JSON.string(object["build_info"]),
            hasVision: JSON.bool(modalities?["vision"]),
            isSleeping: JSON.bool(object["is_sleeping"]),
            contextPerSlot: JSON.int(defaults?["n_ctx"]))
    }

    /// Router mode: paths of the models whose status is "loaded". Unverified
    /// against a live router; tolerant of the endpoint meaning something else.
    static func parseRouterModels(_ data: Data?) -> [String] {
        guard let object = JSON.object(data) else { return [] }
        let entries = JSON.objects(object["data"]) + JSON.objects(object["models"])
        return entries.compactMap { entry in
            guard let path = JSON.string(entry["path"]), !path.isEmpty else { return nil }
            let status = entry["status"] as? [String: Any]
            let value = JSON.string(status?["value"]) ?? JSON.string(entry["status"])
            return value == "loaded" ? path : nil
        }
    }

    // MARK: Probe

    static func inspect(_ draft: RuntimeDraft, client: HTTPClient) async -> ProbeResult {
        guard let port = draft.probePort else { return offline(draft) }
        async let propsData = client.getData(port: port, path: "/props")
        async let slotsData = client.getData(port: port, path: "/slots")
        async let healthAnswer = client.get(port: port, path: "/health")
        async let routerData = client.getData(port: port, path: "/models")
        let props = parseProps(await propsData)
        let slots = parseSlots(await slotsData)
        let health = await healthAnswer
        let routerPaths = parseRouterModels(await routerData)
        return assemble(draft, props: props, slots: slots, healthStatus: health?.status, routerPaths: routerPaths)
    }

    static func offline(_ draft: RuntimeDraft) -> ProbeResult {
        assemble(draft, props: nil, slots: nil, healthStatus: nil, routerPaths: [])
    }

    static func assemble(_ draft: RuntimeDraft, props: LlamaProps?, slots: [LlamaSlot]?, healthStatus: Int?, routerPaths: [String]) -> ProbeResult {
        let process = draft.process
        let arguments = process.record.arguments
        let cwd = process.currentDirectory
        var set = ModelFileSet()
        set.add(contentsOf: process.files)
        set.add(arguments: arguments, cwd: cwd, flags: ["--model", "-m"], role: .text)
        set.add(arguments: arguments, cwd: cwd, flags: ["--mmproj"], role: .projector)
        set.add(arguments: arguments, cwd: cwd, flags: ["--model-draft", "-md"], role: .text)
        set.add(path: props?.modelPath, cwd: cwd, role: .text)
        for path in routerPaths { set.add(path: path, cwd: cwd) }

        let isLoading = healthStatus == 503
        let isBusy: Bool? = slots.map { $0.contains(where: \.isProcessing) }
        let state: ModelState = isLoading ? .loading : (isBusy == true ? .executing : .idle)
        let device: Device = ModelFiles.flagIsZero(arguments, flags: ["-ngl", "--n-gpu-layers", "--gpu-layers"]) ? .cpu : .gpu
        var models = set.models(runtime: .llamaServer, pid: process.pid, device: device, state: state)
        let contextLength = slots?.first?.contextLength ?? props?.contextPerSlot
            ?? ModelFiles.argumentValue(arguments, flags: ["-c", "--ctx-size"]).flatMap { Int($0) }
        if let index = models.firstIndex(where: { $0.role == .text }) ?? models.indices.first {
            models[index].contextLength = contextLength
            if let alias = ModelFiles.argumentValue(arguments, flags: ["-a", "--alias"]), !alias.isEmpty {
                models[index].name = alias
            }
        }
        return ProbeResult(version: props?.buildInfo, isBusy: isLoading ? true : isBusy, models: models,
                           apiAnswered: props != nil || slots != nil || healthStatus != nil)
    }
}
