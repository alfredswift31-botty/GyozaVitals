import Foundation

/// What a process is, decided from its name, path and arguments alone.
nonisolated struct Classification: Hashable, Sendable {
    let kind: RuntimeKind
    /// A llama-server (or `ollama runner`) that Ollama spawned for one model.
    /// It belongs to the Ollama instance rather than being a runtime of its own.
    let isOllamaRunner: Bool

    init(_ kind: RuntimeKind, isOllamaRunner: Bool = false) {
        self.kind = kind
        self.isOllamaRunner = isOllamaRunner
    }
}

nonisolated enum ProcessClassifier {
    /// Nil means "not an AI runtime we know"; the generic mapped-file check
    /// in the scanner may still pick the process up as `.unknown`.
    static func classify(_ process: ProcessRecord, parent: ProcessRecord?) -> Classification? {
        let name = process.name
        let lowerName = name.lowercased()
        let path = process.executablePath ?? ""
        let lowerPath = path.lowercased()
        let arguments = process.arguments
        let subcommand = arguments.count > 1 ? arguments[1] : nil
        let argumentName = process.argumentName ?? ""

        // Ollama: the server, and the runner it spawns per model.
        if name == "ollama" {
            if subcommand == "runner" { return Classification(.ollama, isOllamaRunner: true) }
            if subcommand == "serve" || subcommand == "start" || arguments.isEmpty { return Classification(.ollama) }
            return nil // `ollama run`, `ollama pull`: clients, not runtimes
        }
        if name == "llama-server" || name == "ollama-runner" {
            if parent?.name == "ollama" || lowerPath.contains("ollama") {
                return Classification(.ollama, isOllamaRunner: true)
            }
            return Classification(.llamaServer)
        }

        if lowerName.hasPrefix("koboldcpp") || arguments.contains(where: { $0.hasSuffix("koboldcpp.py") }) {
            return Classification(.koboldcpp)
        }

        if lowerName.hasPrefix("python") {
            let hasMain = arguments.contains { ($0 as NSString).lastPathComponent == "main.py" }
            let mentionsComfy = lowerPath.contains("comfyui") || arguments.contains { $0.lowercased().contains("comfyui") }
            if hasMain && mentionsComfy { return Classification(.comfyUI) }
        }

        // mflux's commands are Python console scripts: the interpreter is argv[0]
        // and the script argv[1], or the script is argv[0] under its own name.
        if lowerName.hasPrefix("mflux-") || argumentName.hasPrefix("mflux-")
            || (arguments.count > 1 && (arguments[1] as NSString).lastPathComponent.hasPrefix("mflux-")) {
            return Classification(.mflux)
        }

        if ["sd", "sd-cli", "sd-server"].contains(name) {
            let modelFlags: Set<String> = ["--model", "-m", "--diffusion-model"]
            let hasModelFlag = arguments.contains { argument in
                modelFlags.contains(argument) || modelFlags.contains { argument.hasPrefix($0 + "=") }
            }
            if hasModelFlag {
                return Classification(.sdcpp)
            }
            return nil
        }

        if lowerName.hasPrefix("whisper") { return Classification(.whisper) }

        // LM Studio: the app and its helpers (names unverified; the inference
        // helper's name has changed across versions, so the bundle path decides).
        if name.contains("LM Studio") || lowerPath.contains("lm studio.app") || name == "lms" || lowerName.hasPrefix("llmster") {
            return Classification(.lmStudio)
        }

        return nil
    }
}
