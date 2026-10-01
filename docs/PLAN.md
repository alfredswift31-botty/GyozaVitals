# GyozaVitals: plan (1.0)

A macOS menu-bar utility that shows, at a glance, every local AI model currently loaded on this Mac: which runtime holds it, how much memory it takes, which app is using it, and the system load behind it. It works across runtimes (Ollama, koboldcpp, llama-server, LM Studio, whisper.cpp, ComfyUI, mflux, stable-diffusion.cpp) because it reads the operating system, not one vendor's API.

**1.0 is read-only.** It never loads, unloads or interrupts anything.

## Why it exists
No existing tool shows, across runtimes at once, which model files are resident, in which process, with how much memory, and which apps are connected to each server. Ollama's own menu bar shows none of this; Stats and iStat Menus know nothing about models; LM Studio and ModelHub only see their own files. The owner runs five runtimes and gets silent evictions, 5-second stalls and swapping with no way to see why.

## What the user sees

**Status item:** the glyph alone when nothing is loaded; the glyph plus one mono number (total model memory, e.g. `12.4G`) when something is. Nothing else, ever, in the bar.

**Popover (340 pt wide, click to open, Esc to close), top to bottom:**
1. **MODELS.** One row per loaded model: name, size, runtime, device (GPU/CPU), used by (app names), state (loading / idle / executing / unloading in N). A red dot only on a model executing a request right now. Empty: `nothing loaded`.
2. **MEMORY.** A stacked bar (app / wired / compressed, with the model share called out), the legend as label-over-value columns (MODELS / APP / WIRED / COMPRESSED / SWAP), a memory-pressure history strip, and **headroom**: "room for ~6 GB more before pressure".
3. **PROCESSOR.** CPU % with the P-core / E-core split, GPU % and GPU memory (hidden when the OS doesn't report it), thermal state as a word (nominal / fair / serious / critical).
4. **POWER.** Battery or power adapter, charging, Low Power Mode.
5. **ACTIVITY.** The last few events: loaded, unloaded, evicted, runtime started/stopped, pressure warning, with times.
6. Footer: Settings… and Quit.

**Settings (grouped Form, 520 pt):** menu-bar content (icon only / model count / model memory), refresh rates (while open / while closed), runtimes to watch with their ports (Ollama 11434, koboldcpp 5001, llama-server 8080, LM Studio 1234, ComfyUI 8188, whisper-server 8080 → disambiguated by probing), open at login.

## How it works

Three sources, merged into one picture every refresh.

### 1. Process scanner (the foundation; no runtime API needed)
Enumerate processes (`proc_listallpids`), keep those owned by the current user (the kernel refuses other users' details without root), and classify by executable name and arguments (`KERN_PROCARGS2`): `ollama`, `llama-server`, `ollama runner`, `koboldcpp*`, `python … main.py` (ComfyUI), `mflux-generate*`, `sd-cli`/`sd-server`, `whisper-server`/`whisper-stream`, LM Studio's helper. For each:
- memory: `proc_pid_rusage` → `ri_phys_footprint` (what Activity Monitor calls Memory);
- **mapped model files**: walk `proc_pidinfo(PROC_PIDREGIONPATHINFO2)` and keep paths ending in `.gguf`, `.safetensors`, `.bin`, `.pth`, `.mlmodelc`; file size from the path;
- open files (`PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`) for runtimes that read rather than map;
- **listening ports** (`PROC_PIDFDSOCKETINFO`, `tcpsi_state == TSI_S_LISTEN`), which also discovers Ollama's per-model runner on its random port.

whisper.cpp does not mmap its model (it reads it into memory), so Whisper is detected by process name and `-m <path>` in its arguments, with memory from the footprint.

### 2. Runtime probes (enrichment; each optional)
| Runtime | Endpoint | Adds |
|---|---|---|
| Ollama | `GET /api/ps`, `/api/version` | model names, `size_vram` (GPU/CPU), `expires_at` (unload countdown), `context_length` |
| Ollama runner / llama-server | `GET /props`, `/slots` | model path, `n_ctx`, **is_processing** (executing) |
| koboldcpp | `/api/v1/model`, `/api/extra/perf`, `/api/extra/version` | model name, idle/queue (executing), tokens/s, vision loaded |
| LM Studio | `/api/v0/models` | loaded models and their context |
| ComfyUI | `/system_stats`, `/queue` | version, running job (executing) |
| whisper-server | `/` reachability only | present |

Ollama model names come from the API; when the API is off, the runner's `--model` blob path is matched against `~/.ollama/models/manifests/**` to recover the name.

### 3. Client attribution
Every refresh, scan all user processes' TCP sockets for connections whose foreign port is one of the detected runtimes' listening ports. The connecting pid is mapped to an app (`NSRunningApplication`: name, bundle id, icon; CLI tools fall back to the executable name). That gives "USED BY GyozaYap, Flow" per runtime, and per model where the runtime hosts one model per port (Ollama runners, kobold, llama-server).

### 4. System metrics (public APIs, no root)
- Memory: `host_statistics64`; used = active + inactive + speculative + wired + compressed − purgeable − external; app = used − wired − compressed; cached = purgeable + external. Pressure: `kern.memorystatus_vm_pressure_level` plus a `DispatchSource` memory-pressure source for transitions. Swap: `vm.swapusage`.
- CPU: `host_processor_info` per core, differenced; P/E split from `hw.nperflevels` and `hw.perflevelN.logicalcpu` (E-cores first, then P). Load average: `getloadavg`.
- GPU: IOKit `IOAccelerator` → `PerformanceStatistics["Device Utilization %"]`, `["In use system memory"]`. **May be absent on macOS 26 for some chips: hide the row, never show 0.**
- Thermal: `ProcessInfo.thermalState` + its notification. Power: `IOPSCopyPowerSourcesInfo`, `isLowPowerModeEnabled`.
- Headroom = free + cached − a reserve of 10 % of RAM, floored at 0, shown only while pressure is normal.

### Not possible without root or private frameworks (and therefore not shown)
CPU frequency, Neural Engine utilisation, per-component watts, per-process GPU %, Apple Intelligence's resident model (its daemons run as root). Apple Intelligence gets one line: "not observable", with availability from `SystemLanguageModel` where the SDK allows.

## Refresh and energy
One coalesced timer with 10 % leeway. While the popover is open: system metrics every 2 s, runtime probes every 5 s. While closed: 15 s and 30 s. Nothing while the display is asleep (`NSWorkspace` sleep/wake notifications). The per-process file-mapping walk is the expensive call: run it only for classified AI processes, and only every probe tick, never per metrics tick. CPU and GPU are smoothed (EMA α = 0.3) and shown as whole percent; memory to one decimal.

## Architecture (Swift 5 mode, default MainActor isolation, macOS 15+)
```
GyozaVitals/
  App/        GyozaVitalsApp (MenuBarExtra .window + Settings scene), AppSettings
  Core/       Model.swift (shared types), VitalsStore (merges sources, schedules),
              SystemMetrics/ (memory, cpu, gpu, thermal, power),
              Processes/ (ProcessScanner, libproc wrappers, ProcessClassifier),
              Runtimes/ (one probe per runtime + ModelRegistry for Ollama manifests),
              Attribution/ (socket scan → ClientApp)
  Design/     Theme.swift (shared with GyozaYap), components
  Views/      StatusItemLabel, VitalsPopover, sections, SettingsView
GyozaVitalsTests/  parsers against recorded JSON, scanner against this test process
                   (mmap a temp .gguf-named file and find it), snapshot tests light/dark
```
`VitalsStore` owns the schedule and holds the latest `SystemSnapshot`, `[LoadedModel]`, `[RuntimeInstance]`, `[ActivityEvent]`. The UI reads the store only; every source is behind a protocol so the UI is snapshot-tested with fixtures.

## Guardrails
- Non-sandboxed, hardened runtime, ad-hoc signed, `LSUIElement`. No helper tool, no sudo, no private frameworks.
- Read-only on the system in 1.0: no HTTP POSTs, no signals to processes.
- Graceful absence: a runtime that's off, a port in use by something else, a missing GPU key, a process that returns EPERM, all produce "unknown", never a crash or a zero that looks real.
- Design per `docs/DESIGN.md`; tokens from `Theme.swift`; no raw colours or sizes in views.

## 1.1 candidates (not in 1.0)
Unload buttons (Ollama `keep_alive: 0`, ComfyUI `/free`) behind a confirmation; a notification when pressure goes critical while a model is executing; SMC fan and power readings; per-process GPU time from IOKit user clients; LM Studio process attribution; a history window.
