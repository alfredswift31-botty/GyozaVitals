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
        #expect(KoboldProbe.positionalModel(["koboldcpp", "x.gguf", "--port", "5001"]) == "x.gguf")
        #expect(KoboldProbe.positionalModel(["koboldcpp", "--usecpu"]) == nil)
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

    @Test(arguments: ProcessClassifierTests.runtimeCases) func classifiesRuntimes(record: ProcessRecord, expected: Classification) {
        #expect(ProcessClassifier.classify(record, parent: nil) == expected)
    }

    static let otherCases: [ProcessRecord] = [
        record("Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", ["/Applications/Safari.app/Contents/MacOS/Safari"]),
        record("Ollama", path: "/Applications/Ollama.app/Contents/MacOS/Ollama", ["/Applications/Ollama.app/Contents/MacOS/Ollama"]),
        record("ollama", path: "/opt/homebrew/bin/ollama", ["ollama", "run", "llama3"]),
        record("python3", path: "/opt/homebrew/bin/python3", ["python3", "main.py"]),
        record("sd", path: "/usr/local/bin/sd", ["sd", "--help"]),
    ]

    @Test(arguments: ProcessClassifierTests.otherCases) func ignoresOtherProcesses(record: ProcessRecord) {
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

    @Test(arguments: ModelRoleTests.roleCases) func guessesRoles(fileName: String, runtime: RuntimeKind, expected: ModelRole) {
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

        let expected = ModelFiles.resolve(url.path, cwd: nil)
        #expect(expected.hasSuffix("/fixture-7b-Q4_K_M.gguf"))
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
        let expected = ModelFiles.resolve(url.path, cwd: nil)
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

// MARK: - Client attribution: helpers collapse to their app

struct ClientResolutionTests {
    static let suffixCases: [(String, String)] = [
        ("Qwen Image Helper (Networking)", "Qwen Image"),
        ("Qwen Image Helper (GPU)", "Qwen Image"),
        ("Qwen Image Helper (Renderer)", "Qwen Image"),
        ("Qwen Image Helper (Plugin)", "Qwen Image"),
        ("Qwen Image Helper", "Qwen Image"),
        ("Qwen Image Networking", "Qwen Image"),
        ("Qwen Image Web Content", "Qwen Image"),
        ("Qwen Image WebContent", "Qwen Image"),
        ("Qwen Image GPU", "Qwen Image"),
        ("Google Chrome Helper (Renderer)", "Google Chrome"),
        ("Code Helper (Plugin)", "Code"),
        ("Safari", "Safari"),
        ("GyozaYap", "GyozaYap"),
        ("Networking", "Networking"),
        ("Helper", "Helper"),
        ("", ""),
    ]

    @Test(arguments: ClientResolutionTests.suffixCases) func stripsHelperSuffixes(name: String, expected: String) {
        #expect(ClientFinder.stripHelperSuffix(name) == expected)
    }

    static func link(_ pid: pid_t, _ name: String, _ path: String?, bundle: String? = nil) -> ProcessChainLink {
        ProcessChainLink(pid: pid, name: name, executablePath: path, bundleIdentifier: bundle)
    }

    static let qwen = "/Applications/Qwen Image.app/Contents/MacOS/Qwen Image"
    static let qwenHelper = "/Applications/Qwen Image.app/Contents/Frameworks/Qwen Image Helper (Networking).app/Contents/MacOS/Qwen Image Helper (Networking)"

    @Test func electronHelperResolvesToTheOuterApp() throws {
        // Helper → app → (launchd). The app's own pid stands for it.
        let chain = [
            Self.link(51, "Qwen Image Helper (Networking)", Self.qwenHelper, bundle: "com.qwen.image.helper.Networking"),
            Self.link(50, "Qwen Image", Self.qwen, bundle: "com.qwen.image"),
        ]
        let resolved = try #require(ClientFinder.resolveApp(chain: chain))
        #expect(resolved.app == ClientApp(pid: 50, name: "Qwen Image", bundleIdentifier: "com.qwen.image"))
        #expect(!resolved.isHelper)

        // The helper alone (its parent unknown) still names the app, as a helper.
        let alone = try #require(ClientFinder.resolveApp(chain: [chain[0]]))
        #expect(alone.app.name == "Qwen Image")
        #expect(alone.app.pid == 51)
        #expect(alone.isHelper)
    }

    @Test func bundleFolderAndLocalizedNameMayDiffer() throws {
        let chain = [
            Self.link(61, "qwen-image-desktop Helper (GPU)",
                      "/Applications/qwen-image-desktop.app/Contents/Frameworks/qwen-image-desktop Helper (GPU).app/Contents/MacOS/qwen-image-desktop Helper (GPU)"),
            Self.link(60, "Qwen Image", "/Applications/qwen-image-desktop.app/Contents/MacOS/qwen-image-desktop", bundle: "com.qwen.image"),
        ]
        let resolved = try #require(ClientFinder.resolveApp(chain: chain))
        #expect(resolved.app.pid == 60)
        #expect(resolved.app.name == "Qwen Image")
    }

    @Test func webKitStyleHelperIsStrippedByName() throws {
        // NSRunningApplication names WebKit's XPC services after the app.
        let chain = [Self.link(70, "Qwen Image Networking", "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking", bundle: "com.apple.WebKit.Networking")]
        let resolved = try #require(ClientFinder.resolveApp(chain: chain))
        #expect(resolved.app.name == "Qwen Image")
        #expect(resolved.isHelper)
    }

    @Test func childToolsBelongToTheAppAbove() throws {
        let chain = [
            Self.link(82, "node", "/usr/local/bin/node"),
            Self.link(81, "sh", "/bin/sh"),
            Self.link(80, "Flow", "/Applications/Flow.app/Contents/MacOS/Flow", bundle: "com.flow.app"),
        ]
        // A shell between them ends the walk: a tool run from a shell is the user's.
        #expect(ClientFinder.resolveApp(chain: chain) == nil)
        let direct = try #require(ClientFinder.resolveApp(chain: [chain[0], chain[2]]))
        #expect(direct.app == ClientApp(pid: 80, name: "Flow", bundleIdentifier: "com.flow.app"))
    }

    @Test func commandLineToolsFromATerminalStayThemselves() {
        let chain = [
            Self.link(92, "curl", "/usr/bin/curl"),
            Self.link(91, "zsh", "/bin/zsh"),
            Self.link(90, "Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", bundle: "com.apple.Terminal"),
        ]
        #expect(ClientFinder.resolveApp(chain: chain) == nil)
        #expect(ClientFinder.resolveApp(chain: [Self.link(93, "ollama", "/opt/homebrew/bin/ollama"), chain[1]]) == nil)
        #expect(ClientFinder.resolveApp(chain: []) == nil)
    }

    @Test func aDifferentAppAboveDoesNotTakeOver() throws {
        let chain = [
            Self.link(96, "GyozaYap", "/Applications/GyozaYap.app/Contents/MacOS/GyozaYap", bundle: "com.gyoza.GyozaYap"),
            Self.link(95, "Xcode", "/Applications/Xcode.app/Contents/MacOS/Xcode", bundle: "com.apple.dt.Xcode"),
        ]
        let resolved = try #require(ClientFinder.resolveApp(chain: chain))
        #expect(resolved.app.pid == 96)
        #expect(resolved.app.name == "GyozaYap")
    }

    @Test func appBundlesOnPaths() {
        let helper = ClientFinder.appBundle(onPath: Self.qwenHelper)
        #expect(helper?.path == "/Applications/Qwen Image.app")
        #expect(helper?.name == "Qwen Image")
        #expect(helper?.nested == true)
        let app = ClientFinder.appBundle(onPath: Self.qwen)
        #expect(app?.path == "/Applications/Qwen Image.app")
        #expect(app?.nested == false)
        #expect(ClientFinder.appBundle(onPath: "/Applications/Ollama.app/Contents/Resources/ollama") == nil)
        #expect(ClientFinder.appBundle(onPath: "/usr/bin/curl") == nil)
    }

    @Test func dedupesPerAppPreferringTheAppItself() {
        let app = ClientApp(pid: 50, name: "Qwen Image", bundleIdentifier: "com.qwen.image")
        let clients = [
            ResolvedClient(app: ClientApp(pid: 70, name: "Qwen Image", bundleIdentifier: "com.apple.WebKit.Networking"), isHelper: true),
            ResolvedClient(app: app, isHelper: false),
            ResolvedClient(app: ClientApp(pid: 52, name: "qwen image", bundleIdentifier: nil), isHelper: true),
            ResolvedClient(app: ClientApp(pid: 200, name: "curl", bundleIdentifier: nil), isHelper: false),
            ResolvedClient(app: ClientApp(pid: 201, name: "curl", bundleIdentifier: nil), isHelper: false),
        ]
        let deduped = ClientFinder.dedupe(clients)
        #expect(deduped == [ClientApp(pid: 200, name: "curl", bundleIdentifier: nil), app])
        #expect(ClientFinder.dedupe([]).isEmpty)
    }

    static func record(_ pid: pid_t, parent: pid_t, _ name: String, _ path: String) -> ProcessRecord {
        ProcessRecord(pid: pid, parentPID: parent, uid: 501, name: name, executablePath: path, arguments: [path],
                      startTime: 1_790_000_000, footprintBytes: 100_000_000)
    }

    @Test func chainsFollowParentsAndStopAtLaunchdLoopsAndStrangers() {
        let app = Self.record(50, parent: 1, "Qwen Image", Self.qwen)
        let helper = Self.record(51, parent: 50, "Qwen Image Helper (Networking)", Self.qwenHelper)
        let orphan = Self.record(60, parent: 59, "node", "/usr/local/bin/node")
        let loopA = Self.record(70, parent: 71, "a", "/x/a")
        let loopB = Self.record(71, parent: 70, "b", "/x/b")
        let byPID = Dictionary(uniqueKeysWithValues: [app, helper, orphan, loopA, loopB].map { ($0.pid, $0) })
        #expect(ClientFinder.chain(from: helper, among: byPID).map(\.pid) == [51, 50])
        #expect(ClientFinder.chain(from: app, among: byPID).map(\.pid) == [50])
        #expect(ClientFinder.chain(from: orphan, among: byPID).map(\.pid) == [60])
        #expect(ClientFinder.chain(from: loopA, among: byPID).map(\.pid) == [70, 71])
        let chain = ClientFinder.chain(from: helper, among: byPID)
        #expect(ClientFinder.chain(chain, passesThrough: [50]))
        #expect(!ClientFinder.chain(chain, passesThrough: [51]), "the client itself is not an ancestor")
    }

    @Test func thisProcessResolvesWithoutCrashing() {
        let processes = ProcessList.currentUserProcesses()
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let me = processes.first { $0.pid == getpid() }
        #expect(me != nil)
        guard let me else { return }
        let chain = ClientFinder.chain(from: me, among: byPID)
        #expect(chain.first?.pid == getpid())
        #expect(chain.count <= ClientFinder.chainLimit)
        #expect(!ClientFinder.chain(chain, passesThrough: [getpid()]))
        // Either the test host is an app (xctest in a bundle) or a tool: both are fine, never a crash.
        if let resolved = ClientFinder.resolveApp(chain: chain) { #expect(!resolved.app.name.isEmpty) }
    }
}

@MainActor
struct ClientResolverTests {
    @Test func resolvesThisProcessToANonEmptyName() {
        let processes = ProcessList.currentUserProcesses()
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        guard let me = processes.first(where: { $0.pid == getpid() }) else {
            Issue.record("this process is missing from the listing")
            return
        }
        var resolver = ClientResolver(chains: [me.pid: ClientFinder.chain(from: me, among: byPID)])
        let clients = resolver.resolve([ClientFinder.client(for: me), ClientFinder.client(for: me)])
        #expect(clients.count == 1)
        #expect(clients.first?.name.isEmpty == false)
        // A pid with no chain falls back to the name it came with.
        let unknown = resolver.resolve([ClientApp(pid: 2_000_000_000, name: "curl", bundleIdentifier: nil)])
        #expect(unknown == [ClientApp(pid: 2_000_000_000, name: "curl", bundleIdentifier: nil)])
    }
}

// MARK: - CPU-time heuristic

struct CPUActivityTests {
    static let busyCases: [(Double, Double, Bool?)] = [
        (0.0, 5.0, false),
        (0.1, 1.0, false),
        (0.25, 1.0, false), // exactly a quarter is not more than a quarter
        (0.26, 1.0, true),
        (1.0, 1.0, true),
        (6.0, 5.0, true), // more than one core
        (0.5, 0.0, nil), // no interval
        (0.5, 0.01, nil), // too short to mean anything
        (-1.0, 1.0, nil), // a counter that went backwards
    ]

    @Test(arguments: CPUActivityTests.busyCases) func busyFromDeltas(cpu: Double, wall: Double, expected: Bool?) {
        #expect(CPUActivity.busy(cpuDelta: cpu, wallDelta: wall) == expected)
    }

    /// (cpu share of a core, system GPU, credited with the GPU) → busy / idle / unknown.
    static let combinedCases: [(Double?, Double?, Bool, Bool?)] = [
        (nil, 0.96, true, nil), // no CPU sample yet: unknown, whatever the GPU says
        (0.30, nil, false, true), // the CPU rule alone
        (0.10, nil, false, false),
        (0.01, 0.96, true, true), // Metal-bound sd.cpp at a hundredth of a core: credited, so busy
        (0.10, 0.96, false, false), // not credited: another candidate out-ranks it, or none stands out
        (0.10, 0.50, true, false), // GPU not busy
        (0.001, 0.80, true, true), // both floors are inclusive
        (0.26, 0.0, false, true), // the CPU rule wins regardless of the GPU
        (0.26, nil, false, true),
    ]

    @Test(arguments: CPUActivityTests.combinedCases) func busyFromCPUAndGPU(share: Double?, gpu: Double?, credited: Bool, expected: Bool?) {
        #expect(CPUActivity.busy(cpuShare: share, gpuUtilization: gpu, gpuCredited: credited) == expected)
    }

    @Test func verdictNamesTheRule() {
        #expect(CPUActivity.verdict(cpuShare: nil, gpuUtilization: 1.0, gpuCredited: true).decidedBy == "first scan")
        #expect(CPUActivity.verdict(cpuShare: 0.3, gpuUtilization: 1.0, gpuCredited: true).decidedBy == "cpu")
        #expect(CPUActivity.verdict(cpuShare: 0.01, gpuUtilization: 1.0, gpuCredited: true).decidedBy == "gpu")
        #expect(CPUActivity.verdict(cpuShare: 0.01, gpuUtilization: 1.0, gpuCredited: false).decidedBy == "none")
        #expect(CPUActivity.verdict(cpuShare: 0.01, gpuUtilization: nil, gpuCredited: true).decidedBy == "none")
    }

    /// (system GPU, candidates by pid with their CPU share) → the pid the GPU is credited to.
    static let creditCases: [(Double?, [pid_t: Double?], pid_t?)] = [
        (1.0, [300: 0.01], 300), // the only candidate, above the floor
        (1.0, [300: 0.01, 920: 0.0], 300), // a sleeping companion doesn't block it
        (1.0, [300: 0.004], 300), // sd.cpp generating on Metal, as measured on the owner's Mac
        (1.0, [300: 0.0005], nil), // under the floor: a game or a video owns the GPU
        (1.0, [300: 0.02, 700: 0.015], nil), // within 2× of each other: neither
        (1.0, [300: 0.02, 700: 0.01], 300), // exactly 2× is enough
        (1.0, [300: 0.01, 700: 0.30], 700), // the upscaler out-ranks an idle sd.cpp
        (1.0, [300: 0.01, 700: nil], 300), // a candidate on its first scan can't be ranked
        (1.0, [300: nil], nil),
        (0.5, [300: 0.30], nil), // GPU not busy
        (nil, [300: 0.30], nil), // GPU not reported
        (1.0, [:], nil),
    ]

    @Test(arguments: CPUActivityTests.creditCases) func theGPUGoesToTheCandidateThatStandsOut(gpu: Double?, candidates: [pid_t: Double?], expected: pid_t?) {
        #expect(CPUActivity.gpuCredit(gpuUtilization: gpu, candidates: candidates) == expected)
    }

    @Test func shareIsCPUOverWall() {
        #expect(CPUActivity.share(cpuDelta: 1, wallDelta: 4) == 0.25)
        #expect(CPUActivity.share(cpuDelta: 1, wallDelta: 0.01) == nil)
        #expect(CPUActivity.share(deltas: []) == nil)
        #expect(CPUActivity.share(deltas: [CPUActivity.Delta(cpuSeconds: 1, wallSeconds: 5), CPUActivity.Delta(cpuSeconds: 1, wallSeconds: 4)]) == 0.4)
    }

    @Test func groupsAddCPUOverTheLongestInterval() {
        #expect(CPUActivity.busy(deltas: []) == nil)
        let quiet = CPUActivity.Delta(cpuSeconds: 0.2, wallSeconds: 5)
        let working = CPUActivity.Delta(cpuSeconds: 1.5, wallSeconds: 5)
        #expect(CPUActivity.busy(deltas: [quiet]) == false)
        #expect(CPUActivity.busy(deltas: [quiet, working]) == true)
        #expect(CPUActivity.busy(deltas: [quiet, quiet, quiet]) == false)
    }

    static func record(_ pid: pid_t, start: UInt64 = 1_790_000_000, cpu: Double) -> ProcessRecord {
        ProcessRecord(pid: pid, parentPID: 1, uid: 501, name: "sd-server", executablePath: "/opt/homebrew/bin/sd-server",
                      arguments: [], startTime: start, footprintBytes: 0, cpuSeconds: cpu)
    }

    @Test func samplesAreKeptPerPidAndStartTime() {
        var activity = CPUActivity()
        #expect(activity.observe([Self.record(10, cpu: 1.0), Self.record(11, cpu: 7.0)], at: 100).isEmpty, "first scan: unknown")
        let second = activity.observe([Self.record(10, cpu: 3.0), Self.record(11, start: 1_790_000_500, cpu: 0.1)], at: 104)
        #expect(second[10] == CPUActivity.Delta(cpuSeconds: 2.0, wallSeconds: 4.0))
        #expect(second[11] == nil, "a restarted pid is a new process")
        #expect(second[10].flatMap { CPUActivity.busy(deltas: [$0]) } == true)
        // A process that skipped a scan starts over.
        #expect(activity.observe([Self.record(11, start: 1_790_000_500, cpu: 0.2)], at: 109)[11] != nil)
        #expect(activity.observe([Self.record(10, cpu: 3.1)], at: 114)[10] == nil)
    }

    @Test func thisProcessReadsAsBusyWhileBurningAndIdleAfter() throws {
        func sample() -> (cpu: Double, wall: TimeInterval) {
            (ProcessList.cpuSeconds(getpid()) ?? -1, ProcessInfo.processInfo.systemUptime)
        }
        let before = sample()
        #expect(before.cpu >= 0, "rusage of our own process is always readable")

        // Two threads spin for 0.6 s: well over a quarter of one core.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        let threads = (0..<2).map { _ in
            Thread {
                var x = 0.0
                while ProcessInfo.processInfo.systemUptime < deadline { x = (x + 1.0).squareRoot() }
                _ = x
            }
        }
        threads.forEach { $0.start() }
        Thread.sleep(forTimeInterval: 0.65)
        let burnt = sample()
        #expect(burnt.cpu > before.cpu)
        #expect(CPUActivity.busy(cpuDelta: burnt.cpu - before.cpu, wallDelta: burnt.wall - before.wall) == true)

        // Then quiet. Other tests may run in parallel in this process, so up
        // to three 0.3 s windows get a chance to read idle.
        var idle = false
        var last = burnt
        for _ in 0..<3 where !idle {
            Thread.sleep(forTimeInterval: 0.3)
            let now = sample()
            idle = CPUActivity.busy(cpuDelta: now.cpu - last.cpu, wallDelta: now.wall - last.wall) == false
            last = now
        }
        #expect(idle, "the process never read as idle after the burn")
    }

    @Test func machTimeConverts() {
        #expect(MachTime.seconds(0) == 0)
        #expect(MachTime.seconds(1_000_000_000) > 0)
        // A tick is 1 ns on Intel and 125/3 ns on Apple silicon: a billion
        // ticks is 1 s or 41.7 s.
        #expect((0.5...60).contains(MachTime.seconds(1_000_000_000)))
    }
}

// MARK: - Assembling runtimes from drafts, probes and the heuristic

struct ScanAssemblyTests {
    static func process(_ pid: pid_t, parent: pid_t = 1, _ name: String, _ path: String, _ arguments: [String], kind: Classification,
                        files: [ModelFile] = [], ports: [Int] = []) -> AIProcess {
        let record = ProcessRecord(pid: pid, parentPID: parent, uid: 501, name: name, executablePath: path, arguments: arguments,
                                   startTime: 1_790_000_000, footprintBytes: 3_000_000_000)
        let sockets = ports.map { TCPSocket(state: .listening, localPort: $0, remotePort: 0, localIsLoopback: true, remoteIsLoopback: false) }
        return AIProcess(record: record, classification: kind, sockets: sockets, files: files, currentDirectory: "/Users/me")
    }

    static let sdFiles = [
        ModelFile(path: "/Users/me/models/qwen-image-Q4_K_M.gguf", sizeBytes: 11_000_000_000),
        ModelFile(path: "/Users/me/models/Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf", sizeBytes: 4_000_000_000),
        ModelFile(path: "/Users/me/models/mmproj-Qwen2.5-VL-7B-Instruct-f16.gguf", sizeBytes: 1_000_000_000),
        ModelFile(path: "/Users/me/models/qwen_image_vae.safetensors", sizeBytes: 250_000_000),
    ]

    static func sdDraft() -> RuntimeDraft {
        let sd = process(300, parent: 50, "sd-server", "/Users/me/sd/sd-server", ["sd-server", "--diffusion-model", "qwen-image-Q4_K_M.gguf", "--port", "7860"],
                         kind: Classification(.sdcpp), files: sdFiles, ports: [7860])
        return RuntimeDraft(kind: .sdcpp, process: sd, helpers: [], probePort: 7860)
    }

    @Test func busyRuntimeWithoutAnAPIMarksEveryFileExecuting() {
        let draft = Self.sdDraft()
        let working: [pid_t: CPUActivity.Delta] = [300: CPUActivity.Delta(cpuSeconds: 4.5, wallSeconds: 5)]
        let busy = ScanPipeline.assemble(drafts: [draft], results: [:], manifests: [:], connections: [:], processes: [:],
                                         cpuDeltas: working, selfPID: 1).result
        #expect(busy.runtimes.count == 1)
        #expect(busy.runtimes.first?.isBusy == true)
        #expect(busy.models.count == Self.sdFiles.count)
        #expect(busy.models.allSatisfy { $0.state == ModelState.executing })

        let resting: [pid_t: CPUActivity.Delta] = [300: CPUActivity.Delta(cpuSeconds: 0.1, wallSeconds: 5)]
        let idle = ScanPipeline.assemble(drafts: [draft], results: [:], manifests: [:], connections: [:], processes: [:],
                                         cpuDeltas: resting, selfPID: 1).result
        #expect(idle.runtimes.first?.isBusy == false)
        #expect(idle.models.allSatisfy { $0.state == ModelState.idle })

        let first = ScanPipeline.assemble(drafts: [draft], results: [:], manifests: [:], connections: [:], processes: [:],
                                          cpuDeltas: [:], selfPID: 1).result
        #expect(first.runtimes.first?.isBusy == nil, "no previous sample: unknown")
        #expect(first.models.allSatisfy { $0.state == ModelState.idle })
        #expect(first.runtimes.first?.diagnostics == BusyDiagnostics(cpuShare: nil, gpuUtilization: nil, candidate: true, decidedBy: "first scan"))
    }

    @Test func anAPIAnswerIsNeverOverriddenAndLoadingStaysLoading() {
        let llama = Self.process(400, "llama-server", "/opt/homebrew/bin/llama-server", ["llama-server", "-m", "x.gguf"],
                                 kind: Classification(.llamaServer), ports: [8080])
        let draft = RuntimeDraft(kind: .llamaServer, process: llama, helpers: [], probePort: 8080)
        func model(_ name: String, _ state: ModelState) -> LoadedModel {
            LoadedModel(id: "400:\(name)", name: name, filePath: nil, runtime: .llamaServer, pid: 400, sizeBytes: 1, device: .gpu,
                        contextLength: nil, expiresAt: nil, state: state, role: .text, clients: [], firstSeen: Date())
        }
        let working: [pid_t: CPUActivity.Delta] = [400: CPUActivity.Delta(cpuSeconds: 5, wallSeconds: 5)]

        let answered = ScanPipeline.assemble(
            drafts: [draft], results: [400: ProbeResult(version: "b1", isBusy: false, models: [model("a", .idle)])],
            manifests: [:], connections: [:], processes: [:], cpuDeltas: working, selfPID: 1).result
        #expect(answered.runtimes.first?.isBusy == false, "the API said idle; CPU time does not override it")
        #expect(answered.models.first?.state == .idle)

        // The process started 5 s ago: a silent API and "loading" is believable.
        let young = Date(timeIntervalSince1970: 1_790_000_005)
        let silent = ScanPipeline.assemble(
            drafts: [draft], results: [400: ProbeResult(version: nil, isBusy: nil, models: [model("a", .idle), model("b", .loading)])],
            manifests: [:], connections: [:], processes: [:], cpuDeltas: working, selfPID: 1, now: young).result
        #expect(silent.runtimes.first?.isBusy == true)
        #expect(silent.models.map(\.state) == [ModelState.executing, ModelState.loading], "idle becomes executing; loading stays")

        // A minute old and not answering: it is working or idle, never still loading.
        let old = Date(timeIntervalSince1970: 1_790_000_060)
        let later = ScanPipeline.assemble(
            drafts: [draft], results: [400: ProbeResult(version: nil, isBusy: nil, models: [model("a", .idle), model("b", .loading)])],
            manifests: [:], connections: [:], processes: [:], cpuDeltas: working, selfPID: 1, now: old).result
        #expect(later.models.map(\.state) == [ModelState.executing, ModelState.executing])
    }

    static func whisperDraft() -> RuntimeDraft {
        let model = ModelFile(path: "/Users/me/.local/share/whisper/ggml-large-v3-turbo-q5_0.bin", sizeBytes: 574_000_000)
        let whisper = process(920, "whisper-stream", "/usr/local/bin/whisper-stream", ["whisper-stream", "-m", model.path],
                              kind: Classification(.whisper), files: [model])
        return RuntimeDraft(kind: .whisper, process: whisper, helpers: [], probePort: nil)
    }

    static func upscalerDraft() -> RuntimeDraft {
        let esrgan = ModelFile(path: "/Users/me/upscalers/RealESRGAN_x4plus.pth", sizeBytes: 64 * 1_048_576)
        let app = process(700, "Qwen Image", ClientResolutionTests.qwen, [ClientResolutionTests.qwen], kind: Classification(.unknown), files: [esrgan])
        return RuntimeDraft(kind: .unknown, process: app, helpers: [], probePort: nil)
    }

    @Test func theGPUIsCreditedToTheCandidateThatStandsOut() {
        let draft = Self.sdDraft()
        // sd.cpp generating on Metal: 10 % of a core, GPU at 96 %.
        let trickle: [pid_t: CPUActivity.Delta] = [300: CPUActivity.Delta(cpuSeconds: 0.5, wallSeconds: 5)]
        let alone = ScanPipeline.assemble(drafts: [draft], results: [:], manifests: [:], connections: [:], processes: [:],
                                          cpuDeltas: trickle, selfPID: 1, gpuUtilization: 0.96).result
        #expect(alone.runtimes.first?.isBusy == true)
        #expect(alone.models.allSatisfy { $0.state == ModelState.executing })
        #expect(alone.runtimes.first?.diagnostics == BusyDiagnostics(cpuShare: 0.1, gpuUtilization: 0.96, candidate: true, decidedBy: "gpu"))
        #expect(alone.runtimes.first?.probeNote == "no api")

        // Without the GPU figure the CPU rule alone says idle.
        let blind = ScanPipeline.assemble(drafts: [draft], results: [:], manifests: [:], connections: [:], processes: [:],
                                          cpuDeltas: trickle, selfPID: 1, gpuUtilization: nil).result
        #expect(blind.runtimes.first?.isBusy == false)
        #expect(blind.runtimes.first?.diagnostics?.decidedBy == "none")

        // The owner's Mac mid-generation: whisper-stream resident (model device
        // unknown, no API) beside sd.cpp at a hundredth of a core, GPU 100 %.
        // whisper is not a candidate, so sd.cpp alone gets the GPU.
        let whisper = Self.whisperDraft()
        let swapping: [pid_t: CPUActivity.Delta] = [300: CPUActivity.Delta(cpuSeconds: 0.05, wallSeconds: 5), 920: CPUActivity.Delta(cpuSeconds: 0.02, wallSeconds: 5)]
        let generating = ScanPipeline.assemble(drafts: [draft, whisper], results: [:], manifests: [:], connections: [:], processes: [:],
                                               cpuDeltas: swapping, selfPID: 1, gpuUtilization: 1.0).result
        #expect(generating.runtimes.first { $0.pid == 300 }?.isBusy == true)
        #expect(generating.runtimes.first { $0.pid == 920 }?.isBusy == false)
        #expect(generating.models.filter { $0.runtime == .sdcpp }.allSatisfy { $0.state == ModelState.executing })
        #expect(generating.models.filter { $0.runtime == .whisper }.allSatisfy { $0.state == ModelState.idle })
        #expect(generating.runtimes.first { $0.pid == 920 }?.diagnostics?.candidate == false)
        #expect(generating.runtimes.first { $0.pid == 920 }?.diagnostics?.decidedBy == "none")

        // Real-ESRGAN upscaling in another process at 100 % GPU while sd.cpp
        // idles: the upscaler at 30 % of a core is busy by the CPU rule on
        // its own merits and sd.cpp, out-ranked, stays idle.
        let upscaler = Self.upscalerDraft()
        let upscaling: [pid_t: CPUActivity.Delta] = [300: CPUActivity.Delta(cpuSeconds: 0.05, wallSeconds: 5), 700: CPUActivity.Delta(cpuSeconds: 1.5, wallSeconds: 5)]
        let upscaled = ScanPipeline.assemble(drafts: [draft, upscaler], results: [:], manifests: [:], connections: [:], processes: [:],
                                             cpuDeltas: upscaling, selfPID: 1, gpuUtilization: 1.0).result
        #expect(upscaled.runtimes.first { $0.pid == 700 }?.isBusy == true)
        #expect(upscaled.runtimes.first { $0.pid == 700 }?.diagnostics?.decidedBy == "cpu")
        #expect(upscaled.runtimes.first { $0.pid == 300 }?.isBusy == false)
        #expect(upscaled.models.filter { $0.runtime == .sdcpp }.allSatisfy { $0.state == ModelState.idle })
        #expect(upscaled.models.contains { $0.role == .upscaler && $0.runtime == .unknown })

        // The upscaler under the quarter-core line but still 2× sd.cpp: it
        // gets the GPU's credit, sd.cpp doesn't.
        let lighter: [pid_t: CPUActivity.Delta] = [300: CPUActivity.Delta(cpuSeconds: 0.05, wallSeconds: 5), 700: CPUActivity.Delta(cpuSeconds: 0.5, wallSeconds: 5)]
        let outranked = ScanPipeline.assemble(drafts: [draft, upscaler], results: [:], manifests: [:], connections: [:], processes: [:],
                                              cpuDeltas: lighter, selfPID: 1, gpuUtilization: 1.0).result
        #expect(outranked.runtimes.first { $0.pid == 700 }?.diagnostics?.decidedBy == "gpu")
        #expect(outranked.runtimes.first { $0.pid == 300 }?.isBusy == false)

        // Two GPU candidates within 2× of each other (0.02 and 0.015): neither.
        let close: [pid_t: CPUActivity.Delta] = [300: CPUActivity.Delta(cpuSeconds: 0.1, wallSeconds: 5), 700: CPUActivity.Delta(cpuSeconds: 0.075, wallSeconds: 5)]
        let undecided = ScanPipeline.assemble(drafts: [draft, upscaler], results: [:], manifests: [:], connections: [:], processes: [:],
                                              cpuDeltas: close, selfPID: 1, gpuUtilization: 1.0).result
        #expect(undecided.runtimes.allSatisfy { $0.isBusy == false })
        #expect(undecided.runtimes.allSatisfy { $0.diagnostics?.candidate == true && $0.diagnostics?.decidedBy == "none" })
        #expect(undecided.models.allSatisfy { $0.state == ModelState.idle })

        // An Ollama whose API answered doesn't count as a candidate.
        let ollama = Self.process(500, "ollama", "/opt/homebrew/bin/ollama", ["ollama", "serve"], kind: Classification(.ollama), ports: [11434])
        let ollamaDraft = RuntimeDraft(kind: .ollama, process: ollama, helpers: [], probePort: 11434)
        let known = ProbeResult(version: "0.19", isBusy: false, models: [LoadedModel(
            id: "500:qwen3:8b", name: "qwen3:8b", filePath: nil, runtime: .ollama, pid: 500, sizeBytes: 1, device: .gpu,
            contextLength: nil, expiresAt: nil, state: .idle, role: .text, clients: [], firstSeen: Date())], apiAnswered: true)
        let withOllama = ScanPipeline.assemble(drafts: [draft, ollamaDraft], results: [500: known], manifests: [:], connections: [:], processes: [:],
                                               cpuDeltas: trickle, selfPID: 1, gpuUtilization: 0.96).result
        #expect(withOllama.runtimes.first { $0.pid == 300 }?.isBusy == true)
        let answered = withOllama.runtimes.first { $0.pid == 500 }
        #expect(answered?.diagnostics?.candidate == false)
        #expect(answered?.diagnostics?.decidedBy == "api")
        #expect(answered?.probeNote == "api answered")
    }

    @Test func candidatesAreGPUHoldersAndImageRuntimes() {
        func model(_ device: Device, role: ModelRole = .text) -> LoadedModel {
            LoadedModel(id: "1:x", name: "x", filePath: nil, runtime: .unknown, pid: 1, sizeBytes: 1, device: device,
                        contextLength: nil, expiresAt: nil, state: .idle, role: role, clients: [], firstSeen: Date())
        }
        #expect(ScanPipeline.isGPUCandidate(kind: .whisper, models: [model(.unknown)]) == false)
        #expect(ScanPipeline.isGPUCandidate(kind: .whisper, models: [model(.gpu)]) == true)
        #expect(ScanPipeline.isGPUCandidate(kind: .llamaServer, models: [model(.cpu)]) == false)
        #expect(ScanPipeline.isGPUCandidate(kind: .llamaServer, models: [model(.split)]) == true)
        #expect(ScanPipeline.isGPUCandidate(kind: .ollama, models: []) == false)
        #expect(ScanPipeline.isGPUCandidate(kind: .sdcpp, models: []) == true)
        #expect(ScanPipeline.isGPUCandidate(kind: .mflux, models: [model(.unknown)]) == true)
        #expect(ScanPipeline.isGPUCandidate(kind: .comfyUI, models: [model(.cpu)]) == true)
        #expect(ScanPipeline.isGPUCandidate(kind: .unknown, models: [model(.unknown, role: .upscaler)]) == true)
        #expect(ScanPipeline.isGPUCandidate(kind: .unknown, models: [model(.unknown, role: .text)]) == false)
    }

    @Test func theProbeNoteSaysHowTheProbeWent() {
        #expect(ScanPipeline.probeNote(for: Self.sdDraft(), probe: .nothing, previous: [:]) == "no api")
        #expect(ScanPipeline.probeNote(for: Self.whisperDraft(), probe: .nothing, previous: [:]) == "no api")
        let llama = Self.process(400, "llama-server", "/opt/homebrew/bin/llama-server", ["llama-server", "-m", "x.gguf"],
                                 kind: Classification(.llamaServer), ports: [8080])
        let listening = RuntimeDraft(kind: .llamaServer, process: llama, helpers: [], probePort: 8080)
        let silent = RuntimeDraft(kind: .llamaServer, process: llama, helpers: [], probePort: nil)
        let remembered = LoadedModel(id: "400:a", name: "a", filePath: nil, runtime: .llamaServer, pid: 400, sizeBytes: 1, device: .gpu,
                                     contextLength: nil, expiresAt: nil, state: .idle, role: .text, clients: [], firstSeen: Date())
        #expect(ScanPipeline.probeNote(for: listening, probe: ProbeResult(version: "b1", isBusy: false, models: [], apiAnswered: true), previous: [:]) == "api answered")
        #expect(ScanPipeline.probeNote(for: listening, probe: .nothing, previous: [:]) == "api timed out")
        #expect(ScanPipeline.probeNote(for: listening, probe: .nothing, previous: ["400:a": remembered]) == "api timed out, carried over")
        #expect(ScanPipeline.probeNote(for: silent, probe: .nothing, previous: [:]) == "no port")
    }

    @Test func ollamaWithNoModelsIsStillARuntime() {
        let ollama = Self.process(500, "ollama", "/Applications/Ollama.app/Contents/Resources/ollama",
                                  ["/Applications/Ollama.app/Contents/Resources/ollama", "serve"], kind: Classification(.ollama), ports: [11434])
        let drafts = ScanPipeline.drafts(from: [ollama], watched: [.ollama, .sdcpp], ports: [:])
        #expect(drafts.count == 1)
        #expect(drafts.first?.kind == .ollama)
        #expect(drafts.first?.probePort == 11434)
        let output = ScanPipeline.assemble(drafts: drafts, results: [500: ProbeResult(version: "0.12.3", isBusy: nil, models: [])],
                                           manifests: [:], connections: [:], processes: [:], cpuDeltas: [:], selfPID: 1)
        #expect(output.result.models.isEmpty)
        #expect(output.result.runtimes.map(\.kind) == [.ollama])
        #expect(output.result.runtimes.first?.version == "0.12.3")
        #expect(output.result.runtimes.first?.footprintBytes == 3_000_000_000, "the footprint counts even with nothing loaded")
        #expect(output.result.runtimes.first?.listeningPorts == [11434])
    }

    @Test func clientsSkipTheServersOwnChildrenAndCarryTheirChains() {
        let draft = Self.sdDraft()
        func record(_ pid: pid_t, parent: pid_t, _ name: String, _ path: String) -> ProcessRecord {
            ProcessRecord(pid: pid, parentPID: parent, uid: 501, name: name, executablePath: path, arguments: [path],
                          startTime: 1_790_000_000, footprintBytes: 1)
        }
        let app = record(50, parent: 1, "Qwen Image", ClientResolutionTests.qwen)
        let helper = record(51, parent: 50, "Qwen Image Helper (Networking)", ClientResolutionTests.qwenHelper)
        let worker = record(301, parent: 300, "sd-worker", "/Users/me/sd/sd-worker")
        let curl = record(900, parent: 1, "curl", "/usr/bin/curl")
        let byPID = Dictionary(uniqueKeysWithValues: [draft.process.record, app, helper, worker, curl].map { ($0.pid, $0) })
        let output = ScanPipeline.assemble(drafts: [draft], results: [:], manifests: [:], connections: [7860: [worker, helper, curl, app]],
                                           processes: byPID, cpuDeltas: [:], selfPID: 1)
        let clients = output.result.runtimes.first?.clients ?? []
        #expect(clients.map(\.pid) == [900, 50, 51], "sorted by name; the server's own child is not a client")
        #expect(output.clientChains[51]?.map(\.pid) == [51, 50])
        #expect(output.clientChains[301] == nil)
        #expect(output.result.models.allSatisfy { $0.clients == clients })

        // The main actor's resolution, without NSRunningApplication: the chain alone collapses the helper.
        let resolved = ClientFinder.dedupe(clients.map { client in
            ClientFinder.resolveApp(chain: output.clientChains[client.pid] ?? [])
                ?? ResolvedClient(app: client, isHelper: false)
        })
        #expect(resolved.map(\.name) == ["curl", "Qwen Image"])
        #expect(resolved.last?.pid == 50)
    }

    /// No connection open at the scan instant, as with an app that polls its
    /// server in short requests: the app that launched the runtime is still
    /// its client, through the parent chain.
    @Test func theLauncherIsAClientWithoutAConnection() {
        let draft = Self.sdDraft()
        func record(_ pid: pid_t, parent: pid_t, _ name: String, _ path: String) -> ProcessRecord {
            ProcessRecord(pid: pid, parentPID: parent, uid: 501, name: name, executablePath: path, arguments: [path],
                          startTime: 1_790_000_000, footprintBytes: 1)
        }
        let app = record(50, parent: 1, "Qwen Image", ClientResolutionTests.qwen)
        let byPID = Dictionary(uniqueKeysWithValues: [draft.process.record, app].map { ($0.pid, $0) })
        let output = ScanPipeline.assemble(drafts: [draft], results: [:], manifests: [:], connections: [:],
                                           processes: byPID, cpuDeltas: [:], selfPID: 1)
        let clients = output.result.runtimes.first?.clients ?? []
        #expect(clients.map(\.pid) == [50])
        #expect(output.clientChains[50]?.map(\.pid) == [50])
        let resolved = ClientFinder.resolveApp(chain: output.clientChains[50] ?? [])
        #expect(resolved?.app.name == "Qwen Image")
    }

    /// A runtime started from a shell names nobody: the shell is a boundary.
    @Test func aShellParentIsNotAClient() {
        let draft = Self.sdDraft()
        let shell = ProcessRecord(pid: 50, parentPID: 1, uid: 501, name: "zsh", executablePath: "/bin/zsh", arguments: ["-zsh"],
                                  startTime: 1_790_000_000, footprintBytes: 1)
        let byPID = Dictionary(uniqueKeysWithValues: [draft.process.record, shell].map { ($0.pid, $0) })
        let output = ScanPipeline.assemble(drafts: [draft], results: [:], manifests: [:], connections: [:],
                                           processes: byPID, cpuDeltas: [:], selfPID: 1)
        #expect(output.result.runtimes.first?.clients.isEmpty == true)
    }
}

// MARK: - Ollama: one model per (server, model), whichever path found it

struct OllamaIdentityTests {
    static let hex = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
    static let projectorHex = "9999999999999999999999999999999999999999999999999999999999999999"
    static let blob = "/Users/me/.ollama/models/blobs/sha256-\(hex)"
    static let projector = "/Users/me/.ollama/models/blobs/sha256-\(projectorHex)"
    static let name = "huihui_ai/qwen3-vl-abliterated:8b-instruct"
    static let manifests = [hex: name, projectorHex: name]

    /// `/api/ps` as Ollama writes it: `digest` is the manifest's digest (the
    /// ID `ollama list` shows), not the blob the runner maps.
    static let ps = """
    {"models":[{"name":"\(name)","model":"\(name)","size":6550000000,"size_vram":3000000000,
      "digest":"sha256:5f6e7d8c9b0a5f6e7d8c9b0a5f6e7d8c9b0a5f6e7d8c9b0a5f6e7d8c9b0a5f6e",
      "details":{"format":"gguf","family":"qwen3vl","families":["qwen3vl"]},
      "expires_at":"2026-10-01T14:02:11.123456+02:00","context_length":32768}]}
    """

    static func server(files: [ModelFile] = []) -> AIProcess {
        ScanAssemblyTests.process(500, "ollama", "/Applications/Ollama.app/Contents/Resources/ollama",
                                  ["/Applications/Ollama.app/Contents/Resources/ollama", "serve"], kind: Classification(.ollama),
                                  files: files, ports: [11434])
    }

    /// The llama-server Ollama spawns for a GGUF model, on its random port.
    static func llamaRunner(pid: pid_t = 501, port: Int? = 54321) -> AIProcess {
        var arguments = ["/Applications/Ollama.app/Contents/Resources/lib/ollama/llama-server", "--model", blob, "--mmproj", projector]
        if let port { arguments += ["--port", "\(port)"] }
        return ScanAssemblyTests.process(pid, parent: 500, "llama-server", arguments[0], arguments, kind: Classification(.ollama, isOllamaRunner: true),
                                         files: [ModelFile(path: blob, sizeBytes: 5_700_000_000), ModelFile(path: projector, sizeBytes: 600_000_000)],
                                         ports: port.map { [$0] } ?? [])
    }

    /// An `ollama runner` on the same blob (the engine's own runner, or a
    /// runner being replaced): one more child mapping the same weights.
    static func ollamaRunner(pid: pid_t = 502) -> AIProcess {
        ScanAssemblyTests.process(pid, parent: 500, "ollama", "/Applications/Ollama.app/Contents/Resources/ollama",
                                  ["/Applications/Ollama.app/Contents/Resources/ollama", "runner", "--ollama-engine", "--model", blob],
                                  kind: Classification(.ollama, isOllamaRunner: true), files: [ModelFile(path: blob, sizeBytes: 5_700_000_000)])
    }

    static func draft(_ processes: [AIProcess]) throws -> RuntimeDraft {
        let drafts = ScanPipeline.drafts(from: processes, watched: [.ollama], ports: [:])
        #expect(drafts.count == 1, "the runners fold into their server")
        return try #require(drafts.first)
    }

    @Test func theAPIEntryAndItsRunnerAreOneModelWithOneId() throws {
        // The server maps the blob too (it reads the GGUF metadata); two children map it.
        let draft = try Self.draft([Self.server(files: [ModelFile(path: Self.blob, sizeBytes: 5_700_000_000)]), Self.llamaRunner(), Self.ollamaRunner()])
        let runners = OllamaProbe.runners(in: draft)
        #expect(runners.count == 2)
        let ps = try #require(OllamaProbe.parsePS(Data(Self.ps.utf8)))

        let listed = OllamaProbe.assemble(draft: draft, version: "0.19.0", ps: ps, runners: runners, manifests: Self.manifests)
        #expect(listed.apiAnswered)
        #expect(listed.models.count == 1, "API entry + llama-server + ollama runner + the server's own mapping = one model")
        let model = try #require(listed.models.first)
        #expect(model.id == "500:\(Self.name)")
        #expect(model.name == Self.name)
        #expect(model.filePath == Self.blob, "the runner that listens stands for the model")
        #expect(model.state == .idle, "listed by the API: not loading")
        #expect(model.device == .split)
        #expect(model.contextLength == 32_768)
        #expect(model.expiresAt != nil)
        #expect(model.sizeBytes == 6_550_000_000)
        #expect(model.role == .vision)

        // The API didn't answer: the runner path gives the same id.
        let offline = OllamaProbe.assemble(draft: draft, version: nil, ps: nil, runners: runners, manifests: Self.manifests)
        #expect(!offline.apiAnswered)
        #expect(offline.models.count == 1)
        #expect(offline.models.first?.id == model.id)
        #expect(offline.models.first?.filePath == Self.blob)
        #expect(offline.models.first?.state == .idle, "no API and the runner silent: idle, the heuristic decides")

        // Through the pipeline: still one, and it is in the carry-over cache.
        let output = ScanPipeline.assemble(drafts: [draft], results: [500: listed], manifests: Self.manifests, connections: [:], processes: [:],
                                           cpuDeltas: [:], selfPID: 1)
        #expect(output.result.models.count == 1)
        #expect(output.result.models.first?.id == model.id)
        #expect(output.apiModels[model.id] != nil)
    }

    @Test func theServersOwnMappingNeverMakesAModel() throws {
        let draft = try Self.draft([Self.server(files: [ModelFile(path: Self.blob, sizeBytes: 5_700_000_000)])])
        #expect(OllamaProbe.runners(in: draft).isEmpty)
        let offline = OllamaProbe.assemble(draft: draft, version: nil, ps: nil, runners: [], manifests: Self.manifests)
        #expect(offline.models.isEmpty)
        let ps = try #require(OllamaProbe.parsePS(Data(Self.ps.utf8)))
        let listed = OllamaProbe.assemble(draft: draft, version: nil, ps: ps, runners: [], manifests: Self.manifests)
        #expect(listed.models.count == 1, "the API alone still lists the model")
        #expect(listed.models.first?.id == "500:\(Self.name)")
    }

    @Test func oneEntryAndOneRunnerPairByElimination() throws {
        // No manifest index (models under a root we didn't find): the only runner is the only entry's.
        let draft = try Self.draft([Self.server(), Self.llamaRunner()])
        let ps = try #require(OllamaProbe.parsePS(Data(Self.ps.utf8)))
        let listed = OllamaProbe.assemble(draft: draft, version: nil, ps: ps, runners: OllamaProbe.runners(in: draft), manifests: [:])
        #expect(listed.models.count == 1)
        #expect(listed.models.first?.filePath == Self.blob)
        #expect(listed.models.first?.state == .idle)
    }

    @Test func anUnlistedRunnerIsLoadingOnlyWhileItDoesNotAnswer() throws {
        let draft = try Self.draft([Self.server(), Self.llamaRunner()])
        var runner = try #require(OllamaProbe.runners(in: draft).first)
        let silent = OllamaProbe.assemble(draft: draft, version: nil, ps: [], runners: [runner], manifests: Self.manifests)
        #expect(silent.models.first?.state == .loading, "the API answered and doesn't list it; /slots didn't answer: loading")
        runner.isProcessing = true
        let serving = OllamaProbe.assemble(draft: draft, version: nil, ps: [], runners: [runner], manifests: Self.manifests)
        #expect(serving.models.first?.state == .executing, "/slots says it is working: not loading")
        #expect(serving.isBusy == true)
    }

    @Test func twoRunnersOnOneBlobKeepTheOneThatListens() {
        let silentFirst = [Self.ollamaRunner(pid: 400), Self.llamaRunner(pid: 401)]
        let unique = OllamaProbe.uniqueRunners(OllamaProbe.runners(in: RuntimeDraft(kind: .ollama, process: Self.server(), helpers: silentFirst, probePort: 11434)))
        #expect(unique.map(\.process.pid) == [401])
        let other = OllamaProbe.runners(in: RuntimeDraft(kind: .ollama, process: Self.server(), helpers: [Self.ollamaRunner(pid: 402), Self.ollamaRunner(pid: 403)], probePort: 11434))
        #expect(OllamaProbe.uniqueRunners(other).map(\.process.pid) == [402], "neither listens: the older one")
    }

    @Test func namesNormalise() {
        #expect(OllamaProbe.normalizedName("registry.ollama.ai/library/qwen3:8b") == "qwen3:8b")
        #expect(OllamaProbe.normalizedName("library/qwen3") == "qwen3:latest")
        #expect(OllamaProbe.normalizedName("hf.co/unsloth/Qwen3-GGUF:Q4_K_M") == "hf.co/unsloth/Qwen3-GGUF:Q4_K_M")
        #expect(OllamaProbe.normalizedName("huihui_ai/qwen3-vl-abliterated:8b-instruct") == "huihui_ai/qwen3-vl-abliterated:8b-instruct")
    }
}

// MARK: - A slow API: last scan's answer carries over

struct CarryOverTests {
    @Test func apiFieldsSurviveATimedOutProbe() throws {
        let draft = try OllamaIdentityTests.draft([OllamaIdentityTests.server(), OllamaIdentityTests.llamaRunner()])
        let runners = OllamaProbe.runners(in: draft)
        let ps = try #require(OllamaProbe.parsePS(Data(OllamaIdentityTests.ps.utf8)))
        let manifests = OllamaIdentityTests.manifests
        // The runner started 100 s before the second scan.
        let now = Date(timeIntervalSince1970: 1_790_000_100)

        let first = ScanPipeline.assemble(
            drafts: [draft], results: [500: OllamaProbe.assemble(draft: draft, version: "0.19.0", ps: ps, runners: runners, manifests: manifests)],
            manifests: manifests, connections: [:], processes: [:], cpuDeltas: [:], selfPID: 1, now: now.addingTimeInterval(-5))
        let listed = try #require(first.result.models.first)
        #expect(listed.device == .split)

        // /api/ps timed out; the runner-only path knows the blob, -ngl and nothing else.
        let timedOut = OllamaProbe.assemble(draft: draft, version: nil, ps: nil, runners: runners, manifests: manifests)
        #expect(timedOut.models.first?.device == .gpu)
        #expect(timedOut.models.first?.expiresAt == nil)
        let resting: [pid_t: CPUActivity.Delta] = [500: CPUActivity.Delta(cpuSeconds: 0.1, wallSeconds: 5), 501: CPUActivity.Delta(cpuSeconds: 0.2, wallSeconds: 5)]
        let second = ScanPipeline.assemble(drafts: [draft], results: [500: timedOut], manifests: manifests, connections: [:], processes: [:],
                                           cpuDeltas: resting, selfPID: 1, previous: first.apiModels, now: now)
        let carried = try #require(second.result.models.first)
        #expect(second.result.models.count == 1)
        #expect(carried.id == listed.id)
        #expect(carried.name == listed.name)
        #expect(carried.filePath == OllamaIdentityTests.blob)
        #expect(carried.device == .split, "the API's device, not the -ngl guess")
        #expect(carried.contextLength == 32_768)
        #expect(carried.expiresAt == listed.expiresAt)
        #expect(carried.sizeBytes == listed.sizeBytes)
        #expect(carried.role == .vision)
        #expect(carried.state == .idle)
        #expect(second.apiModels[carried.id] != nil, "the carried model stays available for the next slow scan")

        // Working meanwhile: the heuristic upgrades idle to executing, never to loading.
        let working: [pid_t: CPUActivity.Delta] = [500: CPUActivity.Delta(cpuSeconds: 0.1, wallSeconds: 5), 501: CPUActivity.Delta(cpuSeconds: 3, wallSeconds: 5)]
        let busy = ScanPipeline.assemble(drafts: [draft], results: [500: timedOut], manifests: manifests, connections: [:], processes: [:],
                                         cpuDeltas: working, selfPID: 1, previous: first.apiModels, now: now)
        #expect(busy.result.models.first?.state == .executing)
    }

    @Test func aCarriedNameRenamesTheRunnerPathsModel() throws {
        // No manifest index at all: the runner path would call the model by its blob.
        let draft = try OllamaIdentityTests.draft([OllamaIdentityTests.server(), OllamaIdentityTests.llamaRunner()])
        let runners = OllamaProbe.runners(in: draft)
        let ps = try #require(OllamaProbe.parsePS(Data(OllamaIdentityTests.ps.utf8)))
        let now = Date(timeIntervalSince1970: 1_790_000_100)
        let first = ScanPipeline.assemble(drafts: [draft], results: [500: OllamaProbe.assemble(draft: draft, version: nil, ps: ps, runners: runners, manifests: [:])],
                                          manifests: [:], connections: [:], processes: [:], cpuDeltas: [:], selfPID: 1, now: now)
        let offline = OllamaProbe.assemble(draft: draft, version: nil, ps: nil, runners: runners, manifests: [:])
        #expect(offline.models.first?.name == "sha256-\(OllamaIdentityTests.hex)")
        let second = ScanPipeline.assemble(drafts: [draft], results: [500: offline], manifests: [:], connections: [:], processes: [:],
                                           cpuDeltas: [:], selfPID: 1, previous: first.apiModels, now: now)
        #expect(second.result.models.first?.id == "500:\(OllamaIdentityTests.name)", "matched by file: the API's name and id")
        #expect(second.result.models.first?.name == OllamaIdentityTests.name)
    }

    @Test func loadingIsBelievedOnlyFromAYoungProcess() throws {
        let draft = try OllamaIdentityTests.draft([OllamaIdentityTests.server(), OllamaIdentityTests.llamaRunner()])
        let loading = LoadedModel(id: "500:x", name: "x", filePath: OllamaIdentityTests.blob, runtime: .ollama, pid: 500, sizeBytes: 1,
                                  device: .gpu, contextLength: nil, expiresAt: nil, state: .loading, role: .text, clients: [], firstSeen: Date())
        let young = ScanPipeline.carryOver([loading], in: draft, previous: [:], now: Date(timeIntervalSince1970: 1_790_000_010))
        #expect(young.first?.state == .loading)
        let old = ScanPipeline.carryOver([loading], in: draft, previous: [:], now: Date(timeIntervalSince1970: 1_790_000_030))
        #expect(old.first?.state == .idle)
        #expect(ScanPipeline.age(of: loading, in: draft, now: Date(timeIntervalSince1970: 1_790_000_030)) == 30)
    }

    @Test func anExpiredUnloadTimeIsNotCarried() throws {
        let draft = try OllamaIdentityTests.draft([OllamaIdentityTests.server(), OllamaIdentityTests.llamaRunner()])
        let past = Date(timeIntervalSince1970: 1_790_000_050)
        let remembered = LoadedModel(id: "500:x", name: "x", filePath: OllamaIdentityTests.blob, runtime: .ollama, pid: 500, sizeBytes: 1,
                                     device: .gpu, contextLength: 4096, expiresAt: past, state: .idle, role: .text, clients: [], firstSeen: Date())
        let fresh = LoadedModel(id: "500:x", name: "x", filePath: OllamaIdentityTests.blob, runtime: .ollama, pid: 500, sizeBytes: 1,
                                device: .gpu, contextLength: nil, expiresAt: nil, state: .idle, role: .text, clients: [], firstSeen: Date())
        let carried = ScanPipeline.carryOver([fresh], in: draft, previous: ["500:x": remembered], now: Date(timeIntervalSince1970: 1_790_000_100))
        #expect(carried.first?.expiresAt == nil)
        #expect(carried.first?.contextLength == 4096)
    }
}

// MARK: - Small upscalers count as weights

struct UpscalerFileTests {
    static let upscalerNames = ["RealESRGAN_x4plus.pth", "4x-UltraSharp.pth", "4xNMKD-Siax_200k.pth", "2x_Loyaldk-SuperPony_500000_V2.0.pth",
                                "GFPGANv1.4.pth", "codeformer.pth", "upscaler.safetensors", "realesr-general-x4v3.pth"]
    static let otherNames = ["qwen-image-Q4_K_M.gguf", "sd_xl_base_1.0_1024x1024.safetensors", "mmproj-f16.gguf", "flux-vae.safetensors", "ggml-base.bin"]

    @Test(arguments: UpscalerFileTests.upscalerNames) func upscalerNamesAreRecognised(name: String) {
        #expect(ModelRoles.isUpscalerName(name))
        #expect(ModelRoles.guess(fileName: name, runtime: .unknown) == .upscaler)
        #expect(ModelRoles.guess(fileName: name, runtime: .sdcpp) == .upscaler)
    }

    @Test(arguments: UpscalerFileTests.otherNames) func otherNamesAreNot(name: String) {
        #expect(!ModelRoles.isUpscalerName(name))
    }

    @Test func upscalerBinFilesArePaths() {
        #expect(ModelFiles.isModelPath("/Users/me/up/RealESRGAN_x4plus.bin"))
        #expect(!ModelFiles.isModelPath("/Users/me/some/random.bin"))
    }

    @Test func floorsByName() {
        let mb: UInt64 = 1_048_576
        #expect(ModelFiles.sizeFloor(forPath: "/m/RealESRGAN_x4plus.pth", minimumBytes: 100 * mb, upscalerMinimumBytes: 32 * mb) == 32 * mb)
        #expect(ModelFiles.sizeFloor(forPath: "/m/RealESRGAN_x4plus.bin", minimumBytes: 100 * mb, upscalerMinimumBytes: 32 * mb) == 32 * mb)
        #expect(ModelFiles.sizeFloor(forPath: "/m/RealESRGAN_x4plus.pth", minimumBytes: 100 * mb, upscalerMinimumBytes: nil) == 100 * mb)
        #expect(ModelFiles.sizeFloor(forPath: "/m/RealESRGAN_x4plus.onnx", minimumBytes: 100 * mb, upscalerMinimumBytes: 32 * mb) == 100 * mb)
        #expect(ModelFiles.sizeFloor(forPath: "/m/1024x1024.safetensors", minimumBytes: 100 * mb, upscalerMinimumBytes: 32 * mb) == 100 * mb)
        #expect(ModelFiles.sizeFloor(forPath: "/m/x.gguf", minimumBytes: 8 * mb, upscalerMinimumBytes: 32 * mb) == 8 * mb, "never raises the bar")
    }

    /// A 64 MB RealESRGAN_x4plus.pth passes the generic filter; a 64 MB
    /// checkpoint with another name and a 20 MB GFPGAN do not.
    @Test func aSmallUpscalerPassesTheGenericFilter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gyozavitals-upscaler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mb: UInt64 = 1_048_576
        func sparse(_ name: String, bytes: UInt64) throws -> String {
            let url = directory.appendingPathComponent(name)
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: bytes)
            try handle.close()
            return url.path
        }
        let esrgan = try sparse("RealESRGAN_x4plus.pth", bytes: 64 * mb)
        let other = try sparse("other_1024x1024.ckpt", bytes: 64 * mb)
        let tiny = try sparse("GFPGANv1.4.pth", bytes: 20 * mb)
        let big = try sparse("big.safetensors", bytes: 100 * mb)
        let paths = [esrgan, other, tiny, big]

        let generic = ModelFiles.files(amongPaths: paths, minimumBytes: ScanPipeline.genericModelFloor, upscalerMinimumBytes: ScanPipeline.upscalerModelFloor)
        #expect(generic.map(\.name).sorted() == ["RealESRGAN_x4plus.pth", "big.safetensors"])
        #expect(generic.first { $0.name.hasPrefix("RealESRGAN") }?.sizeBytes == 64 * mb)
        let strict = ModelFiles.files(amongPaths: paths, minimumBytes: ScanPipeline.genericModelFloor)
        #expect(strict.map(\.name) == ["big.safetensors"])
        let classified = ModelFiles.files(amongPaths: paths, minimumBytes: ScanPipeline.classifiedModelFloor)
        #expect(classified.count == 4, "a classified runtime's floor is lower than all of them")
    }
}

// MARK: - Poller catcher: clients that live for milliseconds

struct PollerCatcherTests {
    /// A loopback listener that accepts in the background and hangs up a
    /// moment later, so curl neither stalls on its request nor vanishes
    /// between the catcher's ticks.
    private final class Listener: @unchecked Sendable {
        let fd: Int32
        let port: Int

        init() throws {
            let server = socket(AF_INET, SOCK_STREAM, 0)
            try #require(server >= 0)
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
            try #require(listen(server, 8) == 0)
            var length = size
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) }
            }
            try #require(named == 0)
            let port = Int(UInt16(bigEndian: address.sin_port))
            try #require(port > 0)
            self.fd = server
            self.port = port
            Thread {
                while true {
                    let connection = accept(server, nil, nil)
                    guard connection >= 0 else { break }
                    usleep(150_000)
                    close(connection)
                }
            }.start()
        }

        func stop() {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    /// Fire and forget: curl connects, sends its request and exits when the
    /// listener hangs up (or after 2 s). It is never signalled.
    private static func spawnCurl(port: Int) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-s", "-m", "2", "http://127.0.0.1:\(port)/"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// One burst of a second, with three curls spawned 200, 300 and 400 ms in.
    private static func burst(_ catcher: PollerCatcher, port: Int, processes byPID: [pid_t: ProcessRecord]) async throws -> [CaughtPoller] {
        let known = Set(ProcessList.allPIDs())
        async let caught = catcher.catchPollers(ports: [port], among: known, processes: byPID, duration: 1.0)
        try await Task.sleep(for: .milliseconds(200))
        var curls: [Process] = []
        for _ in 0..<3 {
            curls.append(try spawnCurl(port: port))
            try await Task.sleep(for: .milliseconds(100))
        }
        let result = await caught
        withExtendedLifetime(curls) {}
        return result
    }

    @Test func catchesCurlConnectingToOurListener() async throws {
        let listener = try Listener()
        defer { listener.stop() }
        let byPID = Dictionary(ProcessList.currentUserProcesses().map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let catcher = PollerCatcher()
        var caught = try await Self.burst(catcher, port: listener.port, processes: byPID)
        // CI runners are slow; one more try before giving up.
        if !caught.contains(where: { $0.name == "curl" }) { caught = try await Self.burst(catcher, port: listener.port, processes: byPID) }
        let curl = try #require(caught.first { $0.name == "curl" }, "caught: \(caught)")
        #expect(curl.port == listener.port)
        #expect(curl.parentPID == getpid())
        #expect(curl.executablePath?.hasSuffix("/curl") == true)
        #expect(curl.chain.first?.pid == curl.pid)
        #expect(curl.chain.first?.name == "curl")
        #expect(curl.chain.dropFirst().first?.pid == getpid(), "chain: \(curl.chain.map(\.pid))")
        #expect(caught.allSatisfy { $0.port == listener.port })
        #expect(!caught.contains { $0.pid == getpid() }, "the test process itself is known, never a newborn")
    }

    @Test func nothingIsCaughtWithoutPortsOrConnections() async {
        let catcher = PollerCatcher()
        let none = await catcher.catchPollers(ports: [], among: [], duration: 1)
        #expect(none.isEmpty)
        // An unused port, a very short burst: whatever is born connects elsewhere.
        let quiet = await catcher.catchPollers(ports: [1], among: Set(ProcessList.allPIDs()), duration: 0.1)
        #expect(quiet.isEmpty)
    }

    @Test func aSocketMatchesInAnyStateButListening() {
        let ports: Set<Int> = [1235]
        func tcp(_ state: TCPSocket.State, remote: Int, loopback: Bool = true) -> TCPSocket {
            TCPSocket(state: state, localPort: 50_000, remotePort: remote, localIsLoopback: loopback, remoteIsLoopback: loopback)
        }
        #expect(PollerCatcher.matches(tcp(.established, remote: 1235), ports: ports))
        #expect(PollerCatcher.matches(tcp(.other, remote: 1235), ports: ports), "SYN_SENT and CLOSE_WAIT count")
        #expect(!PollerCatcher.matches(tcp(.listening, remote: 0), ports: ports))
        #expect(!PollerCatcher.matches(tcp(.established, remote: 443), ports: ports))
        #expect(!PollerCatcher.matches(tcp(.established, remote: 1235, loopback: false), ports: ports))
    }

    @Test func theBurstRuleNeedsPortsNoClientBusyAndACooldown() {
        let now = Date()
        let table: [(ports: Set<Int>, hasClient: Bool, isBusy: Bool, lastBurst: Date?, expected: Bool, why: String)] = [
            ([1235], false, true, nil, true, "busy, listening, nobody seen: burst"),
            ([], false, true, nil, false, "no port: nothing to connect to"),
            ([1235], true, true, nil, false, "a connection or launcher already names the client"),
            ([1235], false, false, nil, false, "idle: no polls to catch"),
            ([1235], false, true, now.addingTimeInterval(-10), false, "watched 10 s ago: sticky clients still hold"),
            ([1235], false, true, now.addingTimeInterval(-ScanPipeline.burstCooldown), true, "the cooldown is over"),
        ]
        for row in table {
            let decision = ScanPipeline.shouldBurst(ports: row.ports, hasClient: row.hasClient, isBusy: row.isBusy, lastBurst: row.lastBurst, now: now)
            #expect(decision == row.expected, Comment(rawValue: row.why))
        }
    }

    static func sdServer() -> RuntimeDraft {
        // Launched by launchd, as on the owner's Mac: the launcher rule names nobody.
        let sd = ScanAssemblyTests.process(300, parent: 1, "sd-server", "/Users/me/sd/sd-server", ["sd-server", "--port", "1235"],
                                           kind: Classification(.sdcpp), files: ScanAssemblyTests.sdFiles, ports: [1235])
        return RuntimeDraft(kind: .sdcpp, process: sd, helpers: [], probePort: 1235)
    }

    @Test func pollersAreHandedToTheRuntimeOnTheirPort() {
        let sd = Self.sdServer()
        let other = ScanAssemblyTests.process(400, "llama-server", "/opt/homebrew/bin/llama-server", ["llama-server"],
                                              kind: Classification(.llamaServer), ports: [8080])
        let llama = RuntimeDraft(kind: .llamaServer, process: other, helpers: [], probePort: 8080)
        let a = CaughtPoller(pid: 1, name: "curl", executablePath: nil, parentPID: 50, port: 1235, chain: [])
        let b = CaughtPoller(pid: 2, name: "curl", executablePath: nil, parentPID: 50, port: 8080, chain: [])
        let stray = CaughtPoller(pid: 3, name: "curl", executablePath: nil, parentPID: 50, port: 9, chain: [])
        let byRuntime = ScanPipeline.pollers([a, b, stray], for: [sd, llama])
        #expect(byRuntime[300]?.map(\.pid) == [1])
        #expect(byRuntime[400]?.map(\.pid) == [2])
        #expect(byRuntime.count == 2)
    }

    /// The owner's case: sd-server under launchd, no connection at the scan
    /// instant, a helper per progress poll. The caught helper is a client,
    /// its chain resolves to the app, and sticky memory keeps it.
    @Test func aCaughtPollerBecomesAClientOfItsRuntime() throws {
        let draft = Self.sdServer()
        let app = ProcessRecord(pid: 50, parentPID: 1, uid: 501, name: "Qwen Image", executablePath: ClientResolutionTests.qwen,
                                arguments: [ClientResolutionTests.qwen], startTime: 1_790_000_000, footprintBytes: 1)
        let byPID = Dictionary(uniqueKeysWithValues: [draft.process.record, app].map { ($0.pid, $0) })
        let helper = CaughtPoller(pid: 38385, name: "curl", executablePath: "/usr/bin/curl", parentPID: 50, port: 1235,
                                  chain: [ProcessChainLink(pid: 38385, name: "curl", executablePath: "/usr/bin/curl"), ProcessChainLink(app)])
        // The server's own worker connecting back to it is not a client.
        let worker = CaughtPoller(pid: 301, name: "sd-worker", executablePath: "/Users/me/sd/sd-worker", parentPID: 300, port: 1235,
                                  chain: [ProcessChainLink(pid: 301, name: "sd-worker", executablePath: "/Users/me/sd/sd-worker"),
                                          ProcessChainLink(draft.process.record)])
        let output = ScanPipeline.assemble(drafts: [draft], results: [:], manifests: [:], connections: [:], processes: byPID,
                                           cpuDeltas: [:], selfPID: 1, pollers: [300: [helper, worker]])
        let runtime = try #require(output.result.runtimes.first)
        #expect(runtime.clients.map(\.pid) == [38385])
        #expect(runtime.clients.first?.name == "curl")
        #expect(runtime.attributionNote == "caught 1 poller")
        #expect(output.clientChains[38385]?.map(\.pid) == [38385, 50])
        #expect(output.clientChains[301] == nil)
        #expect(output.result.models.count == ScanAssemblyTests.sdFiles.count)
        #expect(output.result.models.allSatisfy { $0.clients.map(\.pid) == [38385] })

        // The main actor's resolution, without NSRunningApplication: the chain names the app.
        let resolved = try #require(ClientFinder.resolveApp(chain: output.clientChains[38385] ?? []))
        #expect(resolved.app.name == "Qwen Image")
        #expect(resolved.app.pid == 50)

        // Between bursts, the catch stays for a minute.
        var sticky = StickyClients()
        let now = Date()
        let shown = sticky.update(pid: 300, seen: [resolved.app], now: now)
        #expect(shown.map(\.name) == ["Qwen Image"])
        #expect(sticky.update(pid: 300, seen: [], now: now.addingTimeInterval(45)) == shown)
        #expect(sticky.update(pid: 300, seen: [], now: now.addingTimeInterval(61)).isEmpty)
    }

    @Test func theAttributionNoteNamesTheSources() {
        // Nobody: launchd above, no connection, nothing caught.
        let alone = ScanPipeline.assemble(drafts: [Self.sdServer()], results: [:], manifests: [:], connections: [:], processes: [:],
                                          cpuDeltas: [:], selfPID: 1)
        #expect(alone.result.runtimes.first?.attributionNote == "no client seen")

        // A connection and the launcher, as in 1.0.6.
        let draft = ScanAssemblyTests.sdDraft()
        let app = ProcessRecord(pid: 50, parentPID: 1, uid: 501, name: "Qwen Image", executablePath: ClientResolutionTests.qwen,
                                arguments: [ClientResolutionTests.qwen], startTime: 1_790_000_000, footprintBytes: 1)
        let curl = ProcessRecord(pid: 900, parentPID: 1, uid: 501, name: "curl", executablePath: "/usr/bin/curl", arguments: ["curl"],
                                 startTime: 1_790_000_000, footprintBytes: 1)
        let byPID = Dictionary(uniqueKeysWithValues: [draft.process.record, app, curl].map { ($0.pid, $0) })
        let both = ScanPipeline.assemble(drafts: [draft], results: [:], manifests: [:], connections: [7860: [curl]], processes: byPID,
                                         cpuDeltas: [:], selfPID: 1)
        #expect(both.result.runtimes.first?.attributionNote == "1 connected, launcher")

        // A poller already connected is counted once, as a connection.
        let poller = CaughtPoller(pid: 900, name: "curl", executablePath: "/usr/bin/curl", parentPID: 1, port: 7860, chain: [])
        let once = ScanPipeline.assemble(drafts: [draft], results: [:], manifests: [:], connections: [7860: [curl]], processes: byPID,
                                         cpuDeltas: [:], selfPID: 1, pollers: [300: [poller]])
        #expect(once.result.runtimes.first?.attributionNote == "1 connected, launcher")
        #expect(once.result.runtimes.first?.clients.map(\.pid) == [900, 50])
    }
}
