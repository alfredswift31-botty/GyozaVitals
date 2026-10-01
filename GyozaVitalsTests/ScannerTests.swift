import Darwin
import Foundation
import Testing
@testable import GyozaVitals

// MARK: - Parsers against recorded JSON

struct OllamaParserTests {
    static let ps = """
    {"models":[
      {"name":"huihui_ai/qwen3-vl-abliterated:8b-instruct","model":"huihui_ai/qwen3-vl-abliterated:8b-instruct","size":6550000000,
       "digest":"sha256:a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90",
       "details":{"parent_model":"","format":"gguf","family":"qwen3vl","families":["qwen3vl"],"parameter_size":"8.8B","quantization_level":"Q4_K_M"},
       "expires_at":"2026-10-01T14:02:11.123456+02:00","size_vram":6550000000,"context_length":32768},
      {"name":"hermes3:8b","model":"hermes3:8b","size":4920000000,"digest":"sha256:0011223344556677889900112233445566778899001122334455667788990011",
       "details":{"family":"llama","families":["llama"],"parameter_size":"8.0B","quantization_level":"Q4_0"},
       "expires_at":"2026-10-01T12:00:00Z","size_vram":3000000000,"context_length":8192},
      {"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest","size":274000000,"digest":"sha256:ff",
       "details":{"family":"nomic-bert","families":["nomic-bert"]},"expires_at":"0001-01-01T00:00:00Z","size_vram":0}
    ]}
    """

    @Test func psParsesSizesDevicesAndDates() throws {
        let models = try #require(OllamaProbe.parsePS(Data(Self.ps.utf8)))
        #expect(models.count == 3)
        #expect(models[0].name == "huihui_ai/qwen3-vl-abliterated:8b-instruct")
        #expect(models[0].sizeBytes == 6_550_000_000)
        #expect(models[0].device == .gpu)
        #expect(models[0].contextLength == 32_768)
        #expect(models[0].digestHex == "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90")
        let expires = try #require(models[0].expiresAt)
        // 14:02:11.123456 at +02:00 is 12:02:11.123456 UTC.
        #expect(abs(expires.timeIntervalSince1970 - 1_790_856_131.123456) < 0.001)
        #expect(models[1].device == .split)
        #expect(models[1].expiresAt?.timeIntervalSince1970 == 1_790_856_000)
        #expect(models[2].device == .cpu)
        #expect(models[2].expiresAt == nil, "Go's zero time means never")
        #expect(ModelRoles.guess(ollamaName: models[0].name, families: models[0].families) == .vision)
        #expect(ModelRoles.guess(ollamaName: models[1].name, families: models[1].families) == .text)
        #expect(ModelRoles.guess(ollamaName: models[2].name, families: models[2].families) == .embedding)
    }

    @Test func versionAndGarbage() {
        #expect(OllamaProbe.parseVersion(Data(#"{"version":"0.12.3"}"#.utf8)) == "0.12.3")
        #expect(OllamaProbe.parseVersion(Data("<html>not json".utf8)) == nil)
        #expect(OllamaProbe.parsePS(Data(#"{"data":[]}"#.utf8)) == nil, "another service's JSON is not /api/ps")
        #expect(OllamaProbe.parsePS(nil) == nil)
    }

    @Test func blobAndDigestHex() {
        #expect(OllamaProbe.hex(fromDigest: "sha256:abc123") == "abc123")
        #expect(OllamaProbe.hex(fromBlobPath: "/Users/me/.ollama/models/blobs/sha256-abc123") == "abc123")
        #expect(OllamaProbe.hex(fromBlobPath: "/Users/me/model.gguf") == nil)
    }

    @Test func manifestNamesFromPaths() {
        #expect(OllamaManifests.name(forComponents: ["registry.ollama.ai", "library", "qwen3", "8b"]) == "qwen3:8b")
        #expect(OllamaManifests.name(forComponents: ["registry.ollama.ai", "huihui_ai", "qwen3-vl-abliterated", "8b-instruct"])
            == "huihui_ai/qwen3-vl-abliterated:8b-instruct")
        #expect(OllamaManifests.name(forComponents: ["hf.co", "unsloth", "Qwen3-GGUF", "Q4_K_M"]) == "hf.co/unsloth/Qwen3-GGUF:Q4_K_M")
        #expect(OllamaManifests.name(forComponents: ["x"]) == nil)
    }

    @Test func manifestIndexMapsBlobDigestsToNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gyozavitals-ollama-\(UUID().uuidString)")
        let manifest = root.appendingPathComponent("manifests/registry.ollama.ai/library/hermes3/8b")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = """
        {"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json",
         "config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:cfg","size":488},
         "layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:0011223344","size":4920000000},
                   {"mediaType":"application/vnd.ollama.image.template","digest":"sha256:tpl","size":1500}]}
        """
        try Data(json.utf8).write(to: manifest)
        let names = OllamaManifests.names(roots: [root.path])
        #expect(names["0011223344"] == "hermes3:8b")
        #expect(names["tpl"] == nil)
        let blob = root.appendingPathComponent("blobs/sha256-0011223344").path
        #expect(OllamaManifests.roots(blobPaths: [blob]).first == root.path)
    }
}

struct KoboldParserTests {
    @Test func perfVersionModelAndContext() throws {
        let perf = try #require(KoboldProbe.parsePerf(Data("""
        {"last_process":120,"last_eval":4000,"last_token_count":180,"last_input_count":900,"last_process_time":0.108,"last_eval_time":0.72,
         "last_process_speed":8333.3,"last_eval_speed":250.0,"last_seed":-1,"last_draft_success":0,"last_draft_failed":0,"total_gens":42,
         "stop_reason":1,"total_img_gens":0,"total_tts_gens":0,"total_transcribe_gens":0,"queue":1,"idle":0,"hordeexitcounter":0,
         "uptime":3600.5,"idletime":0.2,"quiet":false}
        """.utf8)))
        #expect(perf.idle == false)
        #expect(perf.queue == 1)
        #expect(perf.lastEvalSpeed == 250)
        #expect(KoboldProbe.parsePerf(Data(#"{"idle":1,"queue":0}"#.utf8))?.idle == true)
        #expect(KoboldProbe.parsePerf(Data(#"{"status":"ok"}"#.utf8)) == nil)

        let version = try #require(KoboldProbe.parseVersion(Data("""
        {"result":"KoboldCpp","version":"1.122.1","protected":false,"llm":true,"txt2img":false,"vision":true,"audio":false,
         "transcribe":false,"multiplayer":false,"websearch":false,"tts":false,"embeddings":false}
        """.utf8)))
        #expect(version.version == "1.122.1")
        #expect(version.hasVision)
        #expect(KoboldProbe.parseVersion(Data(#"{"result":"SomethingElse","version":"1"}"#.utf8)) == nil)
        #expect(KoboldProbe.parseModelName(Data(#"{"result":"koboldcpp/Hermes-3-Llama-3.1-8B.Q4_K_M"}"#.utf8)) == "Hermes-3-Llama-3.1-8B.Q4_K_M")
        #expect(KoboldProbe.parseMaxContext(Data(#"{"value":16384}"#.utf8)) == 16_384)
    }

    @Test func positionalModelArgument() {
        #expect(KoboldProbe.positionalModel(["koboldcpp", "--port", "5001", "models/x.gguf"]) == "models/x.gguf")
        #expect(KoboldProbe.positionalModel(["python3", "koboldcpp.py", "x.gguf"]) == "x.gguf")
        #expect(KoboldProbe.positionalModel(["koboldcpp", "--model", "x.gguf"]) == nil)
    }
}

struct LlamaServerParserTests {
    @Test func slotsPropsAndRouterModels() throws {
        let slots = try #require(LlamaServerProbe.parseSlots(Data("""
        [{"id":0,"id_task":135,"n_ctx":65536,"speculative":false,"is_processing":true,"params":{"n_predict":-1}},
         {"id":1,"id_task":-1,"n_ctx":65536,"speculative":false,"is_processing":false}]
        """.utf8)))
        #expect(slots.count == 2)
        #expect(slots[0].isProcessing && !slots[1].isProcessing)
        #expect(slots[0].contextLength == 65_536)
        #expect(LlamaServerProbe.parseSlots(Data(#"{"error":{"code":501,"message":"This server does not support slots endpoint."}}"#.utf8)) == nil)

        let props = try #require(LlamaServerProbe.parseProps(Data("""
        {"default_generation_settings":{"id":0,"id_task":-1,"n_ctx":8192,"speculative":false,"is_processing":false},
         "total_slots":1,"model_path":"../models/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf","chat_template":"...",
         "modalities":{"vision":false},"build_info":"b6000-abcdef1","is_sleeping":false}
        """.utf8)))
        #expect(props.modelPath == "../models/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf")
        #expect(props.totalSlots == 1)
        #expect(props.contextPerSlot == 8192)
        #expect(props.buildInfo == "b6000-abcdef1")
        #expect(props.hasVision == false)
        #expect(LlamaServerProbe.parseProps(Data(#"{"version":"0.12.3"}"#.utf8)) == nil, "Ollama's JSON is not llama-server's")

        let router = LlamaServerProbe.parseRouterModels(Data("""
        {"data":[{"id":"ggml-org/gemma-3-4b-it-GGUF:Q4_K_M","path":"/Users/me/Library/Caches/llama.cpp/gemma.gguf","status":{"value":"loaded"}},
                 {"id":"other","path":"/Users/me/other.gguf","status":{"value":"unloaded"}}]}
        """.utf8))
        #expect(router == ["/Users/me/Library/Caches/llama.cpp/gemma.gguf"])
    }
}

struct LMStudioParserTests {
    @Test func onlyResidentModelsCount() throws {
        let models = try #require(LMStudioProbe.parseModels(Data("""
        {"object":"list","data":[
          {"id":"qwen2.5-7b-instruct","object":"model","type":"llm","publisher":"lmstudio-community","arch":"qwen2","compatibility_type":"gguf",
           "quantization":"Q4_K_M","state":"loaded","max_context_length":32768,"loaded_context_length":4096},
          {"id":"text-embedding-nomic-embed-text-v1.5","object":"model","type":"embeddings","arch":"nomic-bert","quantization":"Q8_0",
           "state":"loading","max_context_length":2048},
          {"id":"llava-v1.5-7b","object":"model","type":"vlm","state":"not-loaded","max_context_length":4096}
        ]}
        """.utf8)))
        #expect(models.count == 3)
        let resident = models.filter(\.isResident)
        #expect(resident.map(\.id) == ["qwen2.5-7b-instruct", "text-embedding-nomic-embed-text-v1.5"])
        #expect(resident[0].loadedContextLength == 4096)
        #expect(resident[1].state == "loading")
        let file = ModelFile(path: "/Users/me/.lmstudio/models/lmstudio-community/Qwen2.5-7B-Instruct-GGUF/Qwen2.5-7B-Instruct-Q4_K_M.gguf", sizeBytes: 4_700_000_000)
        #expect(LMStudioProbe.match("qwen2.5-7b-instruct", among: [file]) == file)
        #expect(LMStudioProbe.match("llava-v1.5-7b", among: [file]) == nil)
    }
}

struct ComfyUIParserTests {
    @Test func queueAndStats() throws {
        let queue = try #require(ComfyUIProbe.parseQueue(Data("""
        {"queue_running":[[0,"8b5c","prompt",{"client_id":"abc"},["9"]]],"queue_pending":[[1,"c1","p",{},[]],[2,"c2","p",{},[]]]}
        """.utf8)))
        #expect(queue.running == 1)
        #expect(queue.pending == 2)
        #expect(ComfyUIProbe.parseQueue(Data(#"{"queue_running":[],"queue_pending":[]}"#.utf8))?.running == 0)
        #expect(ComfyUIProbe.parseQueue(Data(#"{"models":[]}"#.utf8)) == nil)

        let stats = try #require(ComfyUIProbe.parseStats(Data("""
        {"system":{"os":"posix","ram_total":38654705664,"ram_free":9000000000,"comfyui_version":"0.4.1","python_version":"3.12.4",
                   "pytorch_version":"2.5.0","embedded_python":false,"argv":["main.py"]},
         "devices":[{"name":"mps","type":"mps","index":0,"vram_total":38654705664,"vram_free":9000000000,"torch_vram_total":0,"torch_vram_free":0}]}
        """.utf8)))
        #expect(stats.version == "0.4.1")
        #expect(stats.device == .gpu)
    }
}

struct DateParsingTests {
    @Test func rfc3339WithAnyFraction() {
        #expect(RFC3339.date("2026-10-01T12:02:11Z")?.timeIntervalSince1970 == 1_790_856_131)
        #expect(RFC3339.date("2026-10-01T14:02:11.5+02:00")?.timeIntervalSince1970 == 1_790_856_131.5)
        let nanos = RFC3339.date("2026-10-01T14:02:11.123456789+02:00")?.timeIntervalSince1970
        #expect(nanos != nil && abs(nanos! - 1_790_856_131.123456789) < 0.001)
        #expect(RFC3339.date("not a date") == nil)
    }
}

// MARK: - Classifier and roles

struct ProcessClassifierTests {
    static func record(_ name: String, path: String, _ arguments: [String], parent: pid_t = 1) -> ProcessRecord {
        ProcessRecord(pid: 4242, parentPID: parent, uid: 501, name: name, executablePath: path, arguments: arguments,
                      startTime: 1_790_000_000, footprintBytes: 1_000_000_000)
    }

    static let runtimeCases: [(ProcessRecord, Classification)] = [
        (record("ollama", path: "/Applications/Ollama.app/Contents/Resources/ollama", ["/Applications/Ollama.app/Contents/Resources/ollama", "serve"]),
         Classification(.ollama)),
        (record("ollama", path: "/opt/homebrew/bin/ollama", ["ollama", "runner", "--model", "/Users/me/.ollama/models/blobs/sha256-ab", "--port", "54321"]),
         Classification(.ollama, isOllamaRunner: true)),
        (record("llama-server", path: "/Applications/Ollama.app/Contents/Resources/lib/ollama/llama-server",
                ["/Applications/Ollama.app/Contents/Resources/lib/ollama/llama-server", "--model", "/Users/me/.ollama/models/blobs/sha256-ab"]),
         Classification(.ollama, isOllamaRunner: true)),
        (record("llama-server", path: "/opt/homebrew/bin/llama-server", ["llama-server", "-m", "/Users/me/models/x.gguf", "--port", "8080"]),
         Classification(.llamaServer)),
        (record("koboldcpp-mac-arm64", path: "/Users/me/kobold/koboldcpp-mac-arm64", ["./koboldcpp-mac-arm64", "--model", "x.gguf"]),
         Classification(.koboldcpp)),
        (record("python3.12", path: "/opt/homebrew/bin/python3.12", ["python3", "koboldcpp.py", "--model", "x.gguf"]),
         Classification(.koboldcpp)),
        (record("python3", path: "/Users/me/ComfyUI/.venv/bin/python3", ["python3", "main.py", "--listen"]),
         Classification(.comfyUI)),
        (record("Python", path: "/Users/me/mflux/.venv/bin/Python", ["/Users/me/mflux/.venv/bin/python", "/Users/me/mflux/.venv/bin/mflux-generate", "--model", "schnell"]),
         Classification(.mflux)),
        (record("mflux-generate", path: "/Users/me/.local/bin/mflux-generate", ["mflux-generate", "--model", "dev"]),
         Classification(.mflux)),
        (record("sd-cli", path: "/opt/homebrew/bin/sd-cli", ["sd-cli", "--diffusion-model", "/Users/me/flux.gguf"]),
         Classification(.sdcpp)),
        (record("whisper-server", path: "/opt/homebrew/bin/whisper-server", ["whisper-server", "-m", "ggml-large-v3-turbo.bin"]),
         Classification(.whisper)),
        (record("whisper-stream", path: "/usr/local/bin/whisper-stream", ["whisper-stream", "-m", "models/ggml-base.en.bin"]),
         Classification(.whisper)),
        (record("LM Studio", path: "/Applications/LM Studio.app/Contents/MacOS/LM Studio", ["/Applications/LM Studio.app/Contents/MacOS/LM Studio"]),
         Classification(.lmStudio)),
        (record("LM Studio Helper", path: "/Applications/LM Studio.app/Contents/Frameworks/LM Studio Helper.app/Contents/MacOS/LM Studio Helper", ["x", "--type=utility"]),
         Classification(.lmStudio)),
    ]

    @Test(arguments: runtimeCases) func classifiesRuntimes(record: ProcessRecord, expected: Classification) {
        #expect(ProcessClassifier.classify(record, parent: nil) == expected)
    }

    static let otherCases: [ProcessRecord] = [
        record("Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", ["/Applications/Safari.app/Contents/MacOS/Safari"]),
        record("Ollama", path: "/Applications/Ollama.app/Contents/MacOS/Ollama", ["/Applications/Ollama.app/Contents/MacOS/Ollama"]),
        record("ollama", path: "/opt/homebrew/bin/ollama", ["ollama", "run", "llama3"]),
        record("python3", path: "/opt/homebrew/bin/python3", ["python3", "main.py"]),
        record("sd", path: "/usr/local/bin/sd", ["sd", "--help"]),
    ]

    @Test(arguments: otherCases) func ignoresOtherProcesses(record: ProcessRecord) {
        #expect(ProcessClassifier.classify(record, parent: nil) == nil)
    }

    @Test func runnerIsRecognisedByItsParent() {
        let server = Self.record("ollama", path: "/opt/homebrew/bin/ollama", ["ollama", "serve"])
        let runner = Self.record("llama-server", path: "/opt/homebrew/lib/ollama/llama-server", ["llama-server", "--model", "/x/blobs/sha256-ab"], parent: server.pid)
        #expect(ProcessClassifier.classify(runner, parent: server) == Classification(.ollama, isOllamaRunner: true))
    }
}

struct ModelRoleTests {
    static let roleCases: [(String, RuntimeKind, ModelRole)] = [
        ("qwen3-vl-8b-Q4_K_M.gguf", RuntimeKind.ollama, ModelRole.vision),
        ("Qwen2.5VL-7B-Instruct-Q4_K_M.gguf", .llamaServer, .vision),
        ("llava-v1.6-mistral-7b.Q4_K_M.gguf", .koboldcpp, .vision),
        ("nomic-embed-text-v1.5.f16.gguf", .ollama, .embedding),
        ("bge-reranker-v2-m3-Q8_0.gguf", .llamaServer, .reranker),
        ("mmproj-model-f16.gguf", .llamaServer, .projector),
        ("ggml-large-v3-turbo-q5_0.bin", .whisper, .speech),
        ("ggml-base.en.bin", .unknown, .speech),
        ("Hermes-3-Llama-3.1-8B.Q4_K_M.gguf", .koboldcpp, .text),
        ("devstral-small.gguf", .ollama, .text),
        ("qwen-image-2.1-UC-Q4_K_M.gguf", .comfyUI, .image),
        ("Qwen3VL-8B-Instruct-Q4_K_M.gguf", .comfyUI, .imageEncoder),
        ("t5xxl_fp16.safetensors", .comfyUI, .imageEncoder),
        ("clip_l.safetensors", .mflux, .imageEncoder),
        ("flux-vae.safetensors", .comfyUI, .vae),
        ("ae.safetensors", .mflux, .vae),
        ("4x-UltraSharp.pth", .comfyUI, .upscaler),
        ("RealESRGAN_x4plus.pth", .comfyUI, .upscaler),
        ("flux1-dev.safetensors", .sdcpp, .image),
    ]

    @Test(arguments: roleCases) func guessesRoles(fileName: String, runtime: RuntimeKind, expected: ModelRole) {
        #expect(ModelRoles.guess(fileName: fileName, runtime: runtime) == expected)
    }

    @Test func modelPathsAndArguments() {
        #expect(ModelFiles.isModelPath("/Users/me/models/x.gguf"))
        #expect(ModelFiles.isModelPath("/Users/me/whisper/ggml-base.bin"))
        #expect(!ModelFiles.isModelPath("/Users/me/some/random.bin"))
        #expect(!ModelFiles.isModelPath("/System/Library/x.safetensors"))
        #expect(!ModelFiles.isModelPath("/usr/lib/libSystem.B.dylib"))
        let arguments = ["llama-server", "-m", "a.gguf", "--mmproj=proj.gguf", "--ctx-size", "8192", "-ngl", "0"]
        #expect(ModelFiles.argumentValue(arguments, flags: ["-m", "--model"]) == "a.gguf")
        #expect(ModelFiles.argumentValue(arguments, flags: ["--mmproj"]) == "proj.gguf")
        #expect(ModelFiles.argumentValues(arguments, flags: ["-c", "--ctx-size"]) == ["8192"])
        #expect(ModelFiles.flagIsZero(arguments, flags: ["-ngl"]))
        #expect(!ModelFiles.flagIsZero(arguments, flags: ["--gpulayers"]))
    }

    @Test func procargs2Layout() {
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += Array("/usr/bin/python3".utf8) + [0, 0, 0]
        bytes += Array("python3".utf8) + [0] + Array("main.py".utf8) + [0] + Array("--listen".utf8) + [0]
        bytes += Array("HOME=/Users/me".utf8) + [0]
        #expect(ArgumentReader.parse(bytes) == ["python3", "main.py", "--listen"])
        #expect(ArgumentReader.parse([0, 0, 0, 0]) == [])
    }
}

// MARK: - This very process, through libproc

struct RealProcessTests {
    private static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gyozavitals-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func enumeratesThisProcess() {
        let me = ProcessList.currentUserProcesses().first { $0.pid == getpid() }
        #expect(me != nil)
        #expect(me?.uid == getuid())
        #expect(me?.name.isEmpty == false)
        #expect(me?.executablePath?.hasPrefix("/") == true)
        #expect(me?.arguments.isEmpty == false, "argv of our own process is always readable")
        #expect((me?.footprintBytes ?? 0) > 1_000_000)
        #expect(ProcessList.allPIDs().contains(getpid()))
        #expect(ProcessFiles.currentDirectory(pid: getpid())?.hasPrefix("/") == true)
    }

    @Test func findsAMappedGGUFInThisProcess() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture-7b-Q4_K_M.gguf")
        let length = 1 << 20
        try Data(repeating: 0x47, count: length).write(to: url)
        let fd = open(url.path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        let mapping = try #require(mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0))
        try #require(mapping != UnsafeMutableRawPointer(bitPattern: -1))
        defer { munmap(mapping, length) }
        #expect(mapping.load(as: UInt8.self) == 0x47)

        let expected = url.resolvingSymlinksInPath().path
        let mapped = ProcessFiles.mappedFiles(pid: getpid())
        #expect(mapped.contains(expected), "mapped files were: \(mapped.filter { $0.hasSuffix(".gguf") })")
        let files = ModelFiles.files(amongPaths: mapped, minimumBytes: UInt64(length))
        #expect(files.contains { $0.path == expected && $0.sizeBytes == UInt64(length) })
    }

    @Test func findsAnOpenSafetensorsInThisProcess() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.safetensors")
        try Data(repeating: 0, count: 4096).write(to: url)
        let fd = open(url.path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        let expected = url.resolvingSymlinksInPath().path
        #expect(ProcessFiles.openFiles(pid: getpid()).contains(expected))
    }

    @Test func findsAListeningSocketAndItsClient() throws {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        try #require(server >= 0)
        defer { close(server) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, size) }
        }
        try #require(bound == 0)
        try #require(listen(server, 4) == 0)
        var length = size
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) }
        }
        try #require(named == 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        try #require(port > 0)

        let listening = ProcessFiles.sockets(pid: getpid())
        #expect(listening.contains { $0.state == .listening && $0.localPort == port && $0.localIsLoopback })
        #expect(ProcessFiles.listeningPorts(pid: getpid()).contains(port))

        // A loopback connect completes without an accept; it shows as established on both ends.
        let client = socket(AF_INET, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, size) }
        }
        try #require(connected == 0)
        let sockets = ProcessFiles.sockets(pid: getpid())
        #expect(sockets.contains { $0.state == .established && $0.remotePort == port && $0.remoteIsLoopback })

        let me = try #require(ProcessList.currentUserProcesses().first { $0.pid == getpid() })
        let connections = ClientFinder.connections(to: [port], among: [me])
        #expect(connections[port]?.contains { $0.pid == getpid() } == true)
    }

    @Test func otherUsersProcessesAreSkippedQuietly() {
        // launchd is root's; every read must come back empty, never crash.
        #expect(ProcessFiles.mappedFiles(pid: 1).isEmpty)
        #expect(ProcessFiles.openFiles(pid: 1).isEmpty)
        #expect(ProcessFiles.sockets(pid: 1).isEmpty)
        #expect(ProcessFiles.mappedFiles(pid: 2_000_000_000).isEmpty)
        #expect(ProcessList.footprint(2_000_000_000) == 0)
        #expect(ProcessList.executablePath(2_000_000_000) == nil)
    }
}

@MainActor
struct ModelScannerTests {
    @Test func scansTheRealMachineWithinBudget() async {
        let scanner = ModelScanner()
        let started = Date()
        let result = await scanner.scan(watched: AppSettings.defaultWatched, ports: [:])
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 6, "scan took \(elapsed) s")
        #expect(!result.runtimes.contains { $0.pid == getpid() })
        for model in result.models {
            #expect(model.id.hasPrefix("\(model.pid):"))
            #expect(result.runtimes.contains { $0.pid == model.pid })
        }
        // A second scan keeps first-seen dates stable.
        let again = await scanner.scan(watched: AppSettings.defaultWatched, ports: [:])
        for model in again.models {
            if let earlier = result.models.first(where: { $0.id == model.id }) { #expect(model.firstSeen == earlier.firstSeen) }
        }
    }
}
