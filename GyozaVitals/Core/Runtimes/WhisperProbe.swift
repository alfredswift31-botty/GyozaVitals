import Foundation

// whisper.cpp reads its model into memory rather than mapping it, so the
// model is the `-m <path>` in argv (plus any ggml file it holds open), its
// memory the process footprint. whisper-server answers GET / but says
// nothing about load, so busy stays unknown.

nonisolated enum WhisperProbe {
    static func inspect(_ draft: RuntimeDraft, client: HTTPClient) async -> ProbeResult {
        var result = offline(draft)
        if let port = draft.probePort, await client.get(port: port, path: "/") == nil {
            // Listening but not answering: say nothing rather than guess.
            result.isBusy = nil
        }
        return result
    }

    static func offline(_ draft: RuntimeDraft) -> ProbeResult {
        let process = draft.process
        var set = ModelFileSet()
        set.add(contentsOf: process.files)
        set.add(arguments: process.record.arguments, cwd: process.currentDirectory, flags: ["-m", "--model"], role: .speech)
        let models = set.models(runtime: .whisper, pid: process.pid, device: .unknown, state: .idle)
        return ProbeResult(version: nil, isBusy: nil, models: models)
    }
}
