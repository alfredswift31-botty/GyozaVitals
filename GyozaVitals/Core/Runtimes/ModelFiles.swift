import Darwin
import Foundation

// Model files: which paths count as weights, what a file is for, and the
// argv flags runtimes use to name their models.

/// A weights file a process holds, with its size on disk.
nonisolated struct ModelFile: Hashable, Sendable {
    let path: String
    let sizeBytes: UInt64
    var name: String { (path as NSString).lastPathComponent }
}

nonisolated enum ModelFiles {
    /// Extensions that hold weights. ".bin" only for ggml (whisper) and Core ML.
    static let extensions: Set<String> = ["gguf", "safetensors", "pth", "ckpt", "pt"]

    /// Paths no model lives under; skipped before touching the disk.
    private static let systemPrefixes = ["/System/", "/usr/lib/", "/usr/share/", "/Library/Apple/", "/private/var/db/", "/dev/"]

    static func isModelPath(_ path: String) -> Bool {
        guard !systemPrefixes.contains(where: { path.hasPrefix($0) }) else { return false }
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if extensions.contains(ext) { return true }
        if ext == "bin" {
            return name.hasPrefix("ggml-") || path.contains(".mlmodelc/") || name.contains("whisper") || ModelRoles.isUpscalerName(name)
        }
        return false
    }

    /// Size on disk; nil when the path can't be stat'ed.
    static func size(ofFile path: String) -> UInt64? {
        var status = stat()
        guard stat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        return UInt64(max(0, status.st_size))
    }

    /// Absolute, symlink-resolved path, so argv ("models/x.gguf", "/var/...")
    /// and the kernel ("/private/var/...") describe one file the same way.
    static func resolve(_ path: String, cwd: String?) -> String {
        var full = path
        if !path.hasPrefix("/") {
            if path.hasPrefix("~/") {
                full = (NSHomeDirectory() as NSString).appendingPathComponent(String(path.dropFirst(2)))
            } else if let cwd {
                full = (cwd as NSString).appendingPathComponent(path)
            }
        }
        let standardized = URL(fileURLWithPath: full).standardizedFileURL.path
        // realpath keeps "/private/var" as the kernel reports it; URL's
        // resolvingSymlinksInPath would strip the "/private" and never match.
        guard let real = realpath(standardized, nil) else { return standardized }
        defer { free(real) }
        return String(cString: real)
    }

    /// Model files among a process's mapped and open paths, at least
    /// `minimumBytes` large. Upscalers and face restorers (Real-ESRGAN,
    /// GFPGAN, CodeFormer: 17–70 MB) are small for weights, so a file whose
    /// name says it is one passes at `upscalerMinimumBytes` instead.
    static func files(amongPaths paths: [String], minimumBytes: UInt64, upscalerMinimumBytes: UInt64? = nil) -> [ModelFile] {
        var seen = Set<String>()
        var files: [ModelFile] = []
        for path in paths where isModelPath(path) {
            let resolved = resolve(path, cwd: nil)
            guard seen.insert(resolved).inserted, let size = size(ofFile: resolved) else { continue }
            guard size >= sizeFloor(forPath: resolved, minimumBytes: minimumBytes, upscalerMinimumBytes: upscalerMinimumBytes) else { continue }
            files.append(ModelFile(path: resolved, sizeBytes: size))
        }
        return files
    }

    /// The size a file must reach to count: the upscaler floor when the
    /// name says upscaler and that floor is lower, else the general one.
    static func sizeFloor(forPath path: String, minimumBytes: UInt64, upscalerMinimumBytes: UInt64?) -> UInt64 {
        guard let upscalerMinimumBytes, upscalerMinimumBytes < minimumBytes else { return minimumBytes }
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard ["pth", "pt", "ckpt", "safetensors", "gguf", "bin"].contains(ext), ModelRoles.isUpscalerName(name) else { return minimumBytes }
        return upscalerMinimumBytes
    }

    // MARK: argv

    /// The value after any of the flags ("--model x" or "--model=x").
    static func argumentValue(_ arguments: [String], flags: [String]) -> String? {
        argumentValues(arguments, flags: flags).first
    }

    static func argumentValues(_ arguments: [String], flags: [String]) -> [String] {
        var values: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if flags.contains(argument), index + 1 < arguments.count {
                values.append(arguments[index + 1])
                index += 2
                continue
            }
            for flag in flags where argument.hasPrefix(flag + "=") {
                values.append(String(argument.dropFirst(flag.count + 1)))
            }
            index += 1
        }
        return values
    }

    /// Whether a numeric flag is present and zero ("-ngl 0": CPU only).
    static func flagIsZero(_ arguments: [String], flags: [String]) -> Bool {
        guard let value = argumentValue(arguments, flags: flags) else { return false }
        return Int(value) == 0
    }
}

nonisolated enum ModelRoles {
    /// What a weights file is for, from its name and the runtime's domain.
    static func guess(fileName: String, runtime: RuntimeKind) -> ModelRole {
        let name = fileName.lowercased()
        let ext = (name as NSString).pathExtension
        if name.contains("mmproj") { return .projector }
        switch runtime {
        case .comfyUI, .mflux, .sdcpp:
            return imageRole(name)
        case .whisper:
            return .speech
        default:
            break
        }
        if name.contains("whisper") || (name.hasPrefix("ggml-") && ext == "bin") { return .speech }
        if name.contains("embed") { return .embedding }
        if name.contains("rerank") { return .reranker }
        if isVisionName(name) { return .vision }
        if ["pth", "ckpt", "pt", "safetensors"].contains(ext), runtime == .unknown {
            return imageRole(name) == .image ? .unknown : imageRole(name)
        }
        return .text
    }

    /// Roles inside an image pipeline (ComfyUI, mflux, sd.cpp).
    static func imageRole(_ name: String) -> ModelRole {
        if name.contains("mmproj") { return .projector }
        if name.contains("vae") || name.hasPrefix("ae.") { return .vae }
        if isUpscalerName(name) || name.contains("ultrasharp") { return .upscaler }
        if name.contains("text_encoder") || name.contains("textencoder") || name.contains("clip") || name.contains("t5")
            || name.contains("llava") || name.contains("umt5") || isVisionName(name) {
            return .imageEncoder
        }
        return .image
    }

    /// "RealESRGAN_x4plus", "realesr-general-x4v3", "4x-UltraSharp", "GFPGANv1.4",
    /// "codeformer", "upscaler": a model that enlarges or restores images. The scale
    /// tokens count only at the start of a word ("4x_foo", "4xNMKD"), so
    /// "1024x1024" in a name is not one.
    static func isUpscalerName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if ["esrgan", "realesr", "upscal", "gfpgan", "codeformer"].contains(where: { lower.contains($0) }) { return true }
        let words = lower.split { !$0.isLetter && !$0.isNumber }
        return words.contains { $0.hasPrefix("4x") || $0.hasPrefix("2x") }
    }

    /// "qwen3-vl", "Qwen2.5VL", "llava", "vision", "joycaption": a model that sees.
    static func isVisionName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("vision") || lower.contains("llava") || lower.contains("joycaption") || lower.contains("minicpm-v") {
            return true
        }
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }
        return tokens.contains { token in
            if token == "vl" { return true }
            guard token.hasSuffix("vl"), token.count > 2 else { return false }
            return token.dropLast(2).last?.isNumber == true
        }
    }

    /// Ollama's `details.families` know better than the name.
    static func guess(ollamaName: String, families: [String]) -> ModelRole {
        let lowerFamilies = families.map { $0.lowercased() }
        if lowerFamilies.contains(where: { $0 == "clip" || $0 == "mllama" || $0.hasSuffix("vl") }) { return .vision }
        if lowerFamilies.contains(where: { $0 == "bert" || $0 == "nomic-bert" }) { return .embedding }
        return guess(fileName: ollamaName, runtime: .ollama)
    }
}
