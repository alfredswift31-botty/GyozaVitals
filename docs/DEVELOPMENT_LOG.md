# GyozaVitals development log

GyozaVitals is a macOS menu-bar monitor for local AI models: what's loaded, in which runtime, how much memory, used by which app, and the system load behind it.

## Releases

| Version | Date | Release |
|---|---|---|
| 1.0 | 2026-10-02 | [v1.0](https://github.com/alfredswift31-botty/GyozaVitals/releases/tag/v1.0) |
| 1.0.1 | 2026-10-02 | [v1.0.1](https://github.com/alfredswift31-botty/GyozaVitals/releases/tag/v1.0.1) |

## The brief (1 Oct 2026)
The user runs five local-model projects on one Mac (Ollama for Flow and a character bot, koboldcpp, whisper.cpp, ComfyUI/Qwen Image) and asked for "a menubar utility app for the LLM status and usage and every system details at the tip of the top menu bar": which model is loading, RAM, CPU, "all the system stuff", and which app is using which model. Not an Ollama front end; a dedicated app across runtimes. Minimalist, in the Swiss style of GyozaYap, using the taste-skill.

## Research (three agents, 1 Oct)
- **System metrics without root:** memory, pressure, swap, CPU with P/E split, thermal, battery and low-power are public APIs. GPU utilisation comes from IOKit's `IOAccelerator` `PerformanceStatistics` and may be absent on some macOS 26 chips. CPU frequency, Neural Engine utilisation and per-component watts need private `IOReport` or root `powermetrics`, so they're out.
- **Per-process access:** XNU's `proc_info` only compares the caller's uid with the target's. For the user's own processes, `proc_pid_rusage`, `PROC_PIDLISTFDS`, `PROC_PIDREGIONPATHINFO2` and `PROC_PIDFDSOCKETINFO` all work without root, entitlements or `task_for_pid`. This is what makes "which process holds which model file" and "which app is connected to which runtime" possible. App Sandbox would block it, so the app is not sandboxed.
- **Runtimes:** Ollama `/api/ps` (names, `size_vram`, `expires_at`, `context_length`) and spawns `llama-server` per model on a random port (its `/slots` says if it's executing). koboldcpp `/api/extra/perf` (idle, queue, speeds) but no model path, which comes from argv. ComfyUI has no "loaded" endpoint: mapped `.safetensors` files and `/queue` are the truth. whisper.cpp reads its model rather than mapping it, so Whisper is found by process name and `-m`. LM Studio `/api/v0/models`. Apple Intelligence's daemons run as root: not observable.
- **Nothing like this exists.** Ollama's menu bar shows nothing about loaded models; Stats and iStat know nothing about models; LM Studio and ModelHub only see their own files.
- **Design:** 340 pt popover, 44 pt model rows, 6 pt bars, one visual per section, numbers that never jitter, the one red for "executing". Named **GyozaVitals** (no existing app by that name; GyozaPulse and GyozaMeter were the alternatives).

## Decisions
- Read-only in 1.0. No unload buttons, no POSTs, no signals. The user had an image generation running near the RAM ceiling while this was planned; a monitor must never be the thing that interrupts it.
- Not sandboxed, hardened runtime, ad-hoc signed, `LSUIElement`, no helper tool.
- Shared data types first (`Core/Model.swift`), every source behind a protocol, so the UI is snapshot-tested with fixtures and three modules could be built in parallel.
- `Theme.swift` is copied from GyozaYap, minus its meeting-specific parts, so the two apps share one visual language.
- The app icon is the user's artwork: the rounded square cut out, placed on the macOS icon grid (824 of 1024), exported at every size.

## 1.0: the build (1 Oct 2026)
Three agents built the modules in parallel on their own branches, each against the shared types in `Core/Model.swift`, each proving itself on CI before merging:

- **System metrics** (`Core/SystemMetrics/`): memory with the Activity Monitor formulas and a clamp so app + wired + compressed == used ≤ total; pressure from `kern.memorystatus_vm_pressure_level`; swap; CPU per core, differenced, with the P/E split from `hw.perflevelN` (assumes E-cores have the lowest indices; no public API labels them); GPU from IOKit `IOAccelerator`, nil when the key is missing; thermal; battery. 18 tests, including invariants on the real runner.
- **Scanner** (`Core/Processes`, `Core/Runtimes`, `Core/Attribution`, `Core/Scanner`): same-uid processes with footprint, argv, mapped files (`PROC_PIDREGIONPATHINFO2`), open files and TCP sockets; a classifier for each runtime; a probe per runtime with a 1.5 s GET timeout and a file-based fallback; Ollama's runners folded into the server and their random ports used for attribution; model names recovered from the manifests when `/api/ps` is down; client apps from established loopback connections. 58 tests. The libproc path is proven on the test process itself: it mmaps a `.gguf`-named file, opens a `.safetensors`, listens on a loopback port and connects to it, and the scanner finds all four.
- **UI** (`Views/`, `Theme.swift` additions `Meter` and `PressureStrip`): the popover, the status item with a drawn gyoza glyph (a SwiftUI `Shape` rendered once with `ImageRenderer` as a template image), Settings. Six snapshot cases in light and dark, reviewed from CI three times; two fixes after review (activity block height, legend spacing).
- Integration: `LiveSources` wires `SystemMetrics` and `ModelScanner`; the store starts at launch, not on the first click.

Two CI lessons from the scanner: the SDK struct is `proc_vnodepathinfo` (not `vnode_pathinfo`) and `S_IFMT` imports as `mode_t`; `URL.resolvingSymlinksInPath()` strips `/private`, so paths are compared through `realpath`.

## Verified
CI is green on macOS 26: build, all tests (core, metrics on the real runner, scanner on the real test process, snapshots), the built app checked for `LSUIElement`, no sandbox entitlement and a compiled icon.

## Not verified (needs the user's Mac)
- Ollama with models loaded (names, unload countdown, runner `/slots` "executing"), koboldcpp, and "used by" naming Flow and the bot. The first real run (1.0, see 1.0.1 below) verified sd.cpp, whisper, an idle Ollama and the system figures.
- GPU figures on macOS 26/27 (the IOKit key may be absent on some chips: the row hides).
- The P/E-core index ordering assumption.
- The status glyph on the Clear and Tinted menu bars.
- Energy: the scan is budgeted at ~3 s and runs every 30 s while closed; check Activity Monitor's Energy tab after an hour.

## Known limitations (1.0)
- Ollama's clients are attached to every Ollama model, because a connection to port 11434 doesn't say which model it's for. Only one-model runtimes (llama-server, koboldcpp, whisper) attribute exactly.
- Apple Intelligence shows availability only; its daemons run as root and can't be read.
- No CPU frequency, Neural Engine utilisation or watts (private frameworks or root).
- The app icon is built from a 332 px source, so the two largest sizes are soft.

## Next (1.1 candidates)
Unload buttons behind a confirmation (Ollama `keep_alive: 0`, ComfyUI `/free`); a notification when pressure goes critical while a model is executing; SMC fans and power; per-process GPU time; an icon source at 1024 px.

## 1.0.1: fixes from the first real run (2 Oct 2026)
The user installed 1.0 on a 16 GB Apple-silicon Mac with Qwen Image generating. What worked on the first run: Qwen Image's runtime was identified as **sd.cpp** (not ComfyUI, as the plan had assumed) with all four files (UNet, Qwen3-VL encoder, mmproj, VAE) found through the memory-map scan; Whisper found from its `-m` argument; Ollama detected with no models; pressure *warning*, 4.5 GB swap, GPU 100 %, thermal *fair*, all consistent. The menu bar glyph and number sat at the weight of Apple's own items.

Four things were wrong, all fixed:
- **Fake activity at launch.** The first scan logged everything already running as "started" at launch time. Now the first scan seeds silently; only later changes are logged. (`VitalsStore.hasScanned`.)
- **Helper processes as clients.** The sd.cpp rows said "used by Qwen Image Networking, Qwen Ima…": the Qwen Image app's WebKit/Electron-style helpers, each with its own connection. `ClientFinder` now walks each client's parent chain, resolves it to the owning app (nested `.app` bundle path, or the known helper suffixes), dedupes per app and keeps the app's own pid. The app that launched the server stays a client (it's a sibling, not the server's child).
- **No "executing" without an API.** sd.cpp, mflux, whisper and unknown runtimes showed idle at 100 % GPU. `CPUActivity` keeps `ri_user_time + ri_system_time` per process across scans; cpu/wall > 0.25 of a core marks the runtime busy and its models `.executing`. Applied only when the probe gave no answer; an API's answer is never overridden. First scan: unknown.
- **The memory legend lied about the bar.** MODELS and SWAP sat in the legend as if they were bar segments; MODELS overlaps APP and WIRED (GPU buffers count as wired on Apple silicon), so MODELS 6.0 GB next to APP 2.4 GB looked contradictory. The legend is now APP / WIRED / COMPR. / FREE, exactly the bar; "models 6.0 GB · swap 4.5 GB" is its own line below the pressure strip.
- Also: client names in a row are capped at two plus "+N", and the state column keeps priority.

Still unverified on CI (no sd.cpp there): the 0.25-core busy threshold under real Metal inference, and the Qwen Image helper tree's actual names. The user's next look at the popover during a generation is the check.

## Working notes
- Work goes on `develop`; releases come from `main`.
- To release: run Actions › Build › Run workflow on `main` with `release_tag: vX.Y.Z`.
- To review a design change: push, fetch the build job's log, `python3 scripts/decode-snapshots.py <log> .snapshots/<name>`.
