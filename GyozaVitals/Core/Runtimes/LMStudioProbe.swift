import Foundation

// LM Studio: GET /api/v0/models lists every model it knows with a state;
// the loaded and loading ones are resident. The API names no file and no
// size, so each is matched to a GGUF the helper processes map, by name.
// LM Studio's process names are unverified; the bundle path classifies them.

nonisolated struct LMStudioModel: Hashable, Sendable {
    let id: String
    let type: String?
    let state: String
    let loadedContextLength: Int?
    let maxContextLength: Int?
    let quantization: String?
    let architecture: String?

    var isResident: Bool { state == "loaded" || state == "loading" }
}

nonisolated enum LMStudioProbe {
    static func parseModels(_ data: Data?) -> [LMStudioModel]? {
        guard let object = JSON.object(data), let list = object["data"] as? [Any] else { return nil }
        return list.compactMap { entry in
            guard let item = entry as? [String: Any], let id = JSON.string(item["id"]), !id.isEmpty else { return nil }
            return LMStudioModel(
                id: id, type: JSON.string(item["type"]), state: JSON.string(item["state"]) ?? "not-loaded",
                loadedContextLength: JSON.int(item["loaded_context_length"]), maxContextLength: JSON.int(item["max_context_length"]),
                quantization: JSON.string(item["quantization"]), architecture: JSON.string(item["arch"]))
        }
    }

    static func inspect(_ draft: RuntimeDraft, client: HTTPClient) async -> ProbeResult {
        guard let port = draft.probePort, let listed = parseModels(await client.getData(port: port, path: "/api/v0/models")) else {
            return offline(draft)
        }
        let pid = draft.process.pid
        let files = draft.allProcesses.flatMap(\.files)
        let models = listed.filter(\.isResident).map { entry -> LoadedModel in
            let file = match(entry.id, among: files)
            let role: ModelRole
            switch entry.type {
            case "embeddings", "embedding": role = .embedding
            case "vlm": role = .vision
            case "llm": role = .text
            default: role = file.map { ModelRoles.guess(fileName: $0.name, runtime: .lmStudio) } ?? .unknown
            }
            return LoadedModel(
                id: "\(pid):\(entry.id)", name: entry.id, filePath: file?.path, runtime: .lmStudio, pid: pid,
                sizeBytes: file?.sizeBytes ?? 0, device: .unknown, contextLength: entry.loadedContextLength, expiresAt: nil,
                state: entry.state == "loading" ? .loading : .idle, role: role, clients: [], firstSeen: Date())
        }
        return ProbeResult(version: nil, isBusy: nil, models: models)
    }

    /// Without the API: whatever GGUF the LM Studio processes map.
    static func offline(_ draft: RuntimeDraft) -> ProbeResult {
        var set = ModelFileSet()
        for member in draft.allProcesses { set.add(contentsOf: member.files) }
        return ProbeResult(version: nil, isBusy: nil, models: set.models(runtime: .lmStudio, pid: draft.process.pid, device: .unknown, state: .idle))
    }

    /// "qwen2.5-7b-instruct" matches "Qwen2.5-7B-Instruct-Q4_K_M.gguf".
    static func match(_ id: String, among files: [ModelFile]) -> ModelFile? {
        let key = normalize((id as NSString).lastPathComponent)
        guard !key.isEmpty else { return nil }
        return files.first { normalize(($0.name as NSString).deletingPathExtension).hasPrefix(key) }
            ?? files.first { normalize($0.path).contains(key) }
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
