import Foundation

// ComfyUI: GET /system_stats (version, device) and /queue (a running job
// means executing). It has no loaded-model endpoint: the models are the
// weights the Python process maps (ComfyUI loads safetensors with mmap).

nonisolated struct ComfyStats: Hashable, Sendable {
    let version: String?
    let pythonVersion: String?
    let deviceType: String?
    let vramTotal: UInt64?
    let vramFree: UInt64?

    var device: Device {
        switch (deviceType ?? "").lowercased() {
        case "mps", "cuda", "xpu", "rocm": return .gpu
        case "cpu": return .cpu
        default: return .unknown
        }
    }
}

nonisolated struct ComfyQueue: Hashable, Sendable {
    let running: Int
    let pending: Int
}

nonisolated enum ComfyUIProbe {
    static func parseStats(_ data: Data?) -> ComfyStats? {
        guard let object = JSON.object(data), let system = object["system"] as? [String: Any] else { return nil }
        let device = JSON.objects(object["devices"]).first
        return ComfyStats(
            version: JSON.string(system["comfyui_version"]), pythonVersion: JSON.string(system["python_version"]),
            deviceType: JSON.string(device?["type"]), vramTotal: JSON.uint64(device?["vram_total"]), vramFree: JSON.uint64(device?["vram_free"]))
    }

    static func parseQueue(_ data: Data?) -> ComfyQueue? {
        guard let object = JSON.object(data), let running = object["queue_running"] as? [Any] else { return nil }
        return ComfyQueue(running: running.count, pending: (object["queue_pending"] as? [Any])?.count ?? 0)
    }

    static func inspect(_ draft: RuntimeDraft, client: HTTPClient) async -> ProbeResult {
        guard let port = draft.probePort else { return offline(draft) }
        async let statsData = client.getData(port: port, path: "/system_stats")
        async let queueData = client.getData(port: port, path: "/queue")
        let stats = parseStats(await statsData)
        let queue = parseQueue(await queueData)
        return assemble(draft, stats: stats, queue: queue)
    }

    static func offline(_ draft: RuntimeDraft) -> ProbeResult {
        assemble(draft, stats: nil, queue: nil)
    }

    static func assemble(_ draft: RuntimeDraft, stats: ComfyStats?, queue: ComfyQueue?) -> ProbeResult {
        var set = ModelFileSet()
        set.add(contentsOf: draft.process.files)
        let isBusy: Bool? = queue.map { $0.running > 0 }
        // On Apple silicon ComfyUI runs on MPS unless told otherwise.
        let device = stats?.device ?? (draft.process.record.arguments.contains("--cpu") ? .cpu : .gpu)
        let models = set.models(runtime: .comfyUI, pid: draft.process.pid, device: device, state: isBusy == true ? .executing : .idle)
        return ProbeResult(version: stats?.version, isBusy: isBusy, models: models, apiAnswered: stats != nil || queue != nil)
    }
}
