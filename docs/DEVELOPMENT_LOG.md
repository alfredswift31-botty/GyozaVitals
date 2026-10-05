# GyozaVitals development log

GyozaVitals is a macOS menu-bar monitor for local AI models: what's loaded, in which runtime, how much memory, used by which app, and the system load behind it.

## Releases

| Version | Date | Release |
|---|---|---|
| 1.0 | 2026-10-02 | [v1.0](https://github.com/alfredswift31-botty/GyozaVitals/releases/tag/v1.0) |
| 1.0.1 | 2026-10-02 | [v1.0.1](https://github.com/alfredswift31-botty/GyozaVitals/releases/tag/v1.0.1) |
| 1.0.2 | 2026-10-02 | [v1.0.2](https://github.com/alfredswift31-botty/GyozaVitals/releases/tag/v1.0.2) |
| 1.0.3 | 2026-10-02 | [v1.0.3](https://github.com/alfredswift31-botty/GyozaVitals/releases/tag/v1.0.3) |
| 1.0.4 | 2026-10-02 | [v1.0.4](https://github.com/alfredswift31-botty/GyozaVitals/releases/tag/v1.0.4) |
| 1.0.5 | 2026-10-05 | [v1.0.5](https://github.com/alfredswift31-botty/GyozaVitals/releases/tag/v1.0.5) |
| 1.0.6 | 2026-10-05 | [v1.0.6](https://github.com/alfredswift31-botty/GyozaVitals/releases/tag/v1.0.6) |
| 1.0.7 | 2026-10-05 | [v1.0.7](https://github.com/alfredswift31-botty/GyozaVitals/releases/tag/v1.0.7) |
| 1.0.8 | 2026-10-05 | [v1.0.8](https://github.com/alfredswift31-botty/GyozaVitals/releases/tag/v1.0.8) |

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
- Ollama's own "executing" state (its newer engine's runner may not answer `/slots`; the heuristic covers it), koboldcpp, and "used by" naming Flow and the bot. Ollama names, countdown and "used by Qwen Image" were verified on 1.0.2; sd.cpp's red dot on 1.0.4. The first real run (1.0, see 1.0.1 below) verified sd.cpp, whisper, an idle Ollama and the system figures.
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

## 1.0.2: the second real run (2 Oct 2026)
Two screenshots from the user: the prompt helper working (Ollama's Qwen3-VL) and an image generating (sd.cpp). Verified from them: helper processes collapse to "Qwen Image"; the legend matches the bar; no fake activity at launch; "used by Qwen Image" on an Ollama model (the prompt helper calls Ollama). Also learned: the Real-ESRGAN upscale runs in a different process from sd.cpp, so the 1.0.1 CPU heuristic was right not to mark sd.cpp busy during it.

The owner's 16 GB Mac under 7 GB of swap, Qwen Image (sd.cpp) generating and Ollama holding Qwen3-VL. Three scanner defects:

- **The same Ollama model twice.** Root cause: `/api/ps` reports the model's *manifest* digest (the ID `ollama list` shows), while the runner's `--model` blob is named by the `image.model` *layer* digest. `OllamaProbe.assemble` matched the two by digest, which never succeeds, so every listed model came out twice: once from the API entry (idle) and once as an "unlisted runner" (loading), both with the id `"<server pid>:<name>"` because the manifest index resolves the blob to the same name. Hence one "loaded" event and two "evicted". Now an entry is matched to its runner by the manifest name of the runner's blob (normalised: no registry, no `library/`, `:latest` implied) and, when one entry and one runner remain, by elimination; two child processes on one blob (an `ollama runner` and a `llama-server`, or a runner being replaced) collapse to the one that listens; the server's own mapping of a blob never makes a model; an unlisted runner that answers `/slots` is serving, not loading.
- **"loading" for a model serving requests.** Under memory pressure `/api/ps` outran the 1.5 s GET timeout and the picture fell back to the runner. GETs now time out at 4 s (`HTTPClient.defaultTimeout`; the per-probe deadline is 5 s, still off the main actor), and `ScanPipeline` keeps the API's last answer per model id (`apiModels`): when a probe fails or times out while its process is still there, the fallback's models take the remembered name (so the id), device, context, role, size and unload time, and are never `.loading` unless the process holding the model is younger than 20 s.
- **No "executing" on Metal-bound generation.** sd.cpp at 96 % GPU stayed under a quarter of a core. `VitalsStore` hands the latest system GPU utilisation to the scanner (`ModelScanSource.noteSystemGPU`, a default no-op) and `CPUActivity.busy(cpuShare:gpuUtilization:gpuCandidates:)` adds: GPU ≥ 80 % and the runtime at ≥ 3 % of a core and it is the only GPU-using runtime whose busy state no API gave. The last condition is the guard for the earlier false positive (Real-ESRGAN upscaling in another process at 100 % GPU while sd.cpp idled: two candidates, neither credited).
- The memory line now says "models resident": the footprint counts only touched pages, so a freshly mapped file reads small until it is used (1.5 GB right after sd.cpp restarted, 6 GB after a generation).
- Also: upscalers and face restorers (`esrgan`, `realesr`, `upscal`, `gfpgan`, `codeformer`, a `4x`/`2x` word) pass the generic weights filter at 32 MB instead of 100 MB, so a 64 MB RealESRGAN_x4plus.pth shows up as an `.unknown` runtime with role `.upscaler` and gets the busy heuristic.

Unverifiable on CI (no runtimes there): the 4 s timeout against a pressured Ollama, the 3 % companion floor on real Metal work, and whether Ollama's process tree on the owner's version matches the fixtures (`llama-server` child for GGUF, `ollama runner` for the engine's own).

## 1.0.3: the busy rule, third attempt, and a diagnostics pane (2 Oct 2026)
1.0.2 mid-generation on the user's Mac: sd.cpp at step 11 of 17, 215 s per step, GPU 100 %, swap 6 GB, and still no `.executing`. Everything else in that screenshot was right (one row per model, "Qwen Image", legend summing to 16 GB, "models resident").

Why the 1.0.2 rule failed: it credited the GPU only with exactly one candidate, and whisper.cpp counted as one because its model's device is `.unknown` rather than `.cpu`. With whisper resident there were always two candidates. The 3 % CPU floor was probably also above what a swap-bound Metal loop uses.

- **Rule now:** candidates are runtimes with no API answer that hold a `.gpu`/`.split` model or are image runtimes (sd.cpp, mflux, ComfyUI, an unknown process with an upscaler file); whisper with unknown-device models is not one. At GPU ≥ 80 %, the candidate with the highest CPU share is credited, if it has at least 0.5 % of a core and twice the next candidate's share (or is alone). That keeps the upscaler guard: an upscaling process out-ranks an idle sd.cpp. CPU > 25 % of a core is still busy on its own; an API answer is never overridden.
- **Diagnostics pane** at the bottom of Settings: one line per runtime with the probe note ("api answered", "no api", "api timed out, carried over"), CPU share, GPU utilisation, candidate or not, and which signal decided. Two attempts at this rule were tuned from outside the app; the next one is read from inside it.

Unverified until the user's next screenshot: the 0.5 % floor against real Metal work.

## 1.0.4: the number from the diagnostics pane (2 Oct 2026)
First screenshot of the pane, mid-generation: `sd.cpp · api: no api · cpu 0.004 · gpu 1.00 · candidate · decided by none`; `ollama · cpu 0.000 · not a candidate`; `whisper.cpp · cpu 0.003 · not a candidate`. The rule had the right candidate and a busy GPU, and rejected it because the CPU floor was 0.005 and sd.cpp generating on Metal reads 0.004: a Metal loop is almost entirely GPU. The floor is now 0.001. Idle runtimes read 0.000, so the margin that protects the upscaler case survives. Two releases of guessing from the outside; one screenshot from the inside. The pane stays.

**Verified by the user on 1.0.4:** mid-generation, all four sd.cpp rows carry the red dot, whisper none, GPU 100 %. The red dot has now been seen working on a real Metal workload.

Also confirmed by the 1.0.2 prompt-helper screenshot: one Ollama row, a live unload countdown, no "loading", "used by Qwen Image".

## 1.0.5: clients between polls (5 Oct 2026)
A health check from the user three days on: red dots on all sd.cpp rows with `cpu 0.022 · gpu 1.00 · decided by gpu`, whisper and the idle Ollama correctly not candidates, memory summing to 16 GB, pressure warnings logged with times. One gap: the sd.cpp rows read `sd.cpp · gpu` with no `· Qwen Image`, where earlier scans had shown the app. Attribution was point-in-time: only connections open at the scan instant. An app that drives its runtime with short polling requests is usually between polls when a scan lands. `StickyClients` now keeps a runtime's last non-empty client list for 60 s after the last sighting, and forgets runtimes that are gone so a reused pid can't inherit clients. Trade-off, deliberate: an app that quits can linger on a row for up to a minute.

## 1.0.6: the launcher is a client (5 Oct 2026)
1.0.5 freshly launched, image generating: the sd.cpp rows still read `sd.cpp · gpu` with no app. Sticky clients only help after one sighting, and a 5 s sampler can go minutes without catching a request that lasts milliseconds. The stronger signal was unused: the runtime's own parent chain. sd-server was launched by Qwen Image, and that is true on every scan. `clients(for:)` now adds the runtime's launcher, resolved through the same chain logic as a connecting process, unless the parent is a boundary (a shell, launchd). The runtime's own app is excluded on the main actor by name (Ollama.app launching `ollama serve` is not Ollama's client). Connections remain the second source, so a tool like `curl` still shows.

## 1.0.7: catching the pollers (5 Oct 2026)
Measured on the owner's Mac with 1.0.6 running: sd-server (pid 18226) is a child of launchd, so the launcher rule names nobody, and `netstat -anv` during a generation shows only TIME_WAIT connections to 127.0.0.1:1235 whose pids climb (38385, 38397, 38410, …): Qwen Image drives sd-server with one short-lived helper per progress poll, alive for milliseconds, curl-like. The app itself never holds a connection, so no 5 s scan ever lands on one and "used by" stays empty. `PollerCatcher` (an actor, off the main actor whoever calls it) watches for newborn processes for a 1.2 s burst: `proc_listallpids` every 20 ms, then for each pid not seen before its owner, parent, name and TCP sockets; a newborn with a loopback socket to one of the runtime's ports, in any state, is a poller, re-checked each tick for 150 ms in case it hasn't connected yet. Its parent chain is built from the scan's process snapshot, so the main actor resolves it to the app exactly like a connecting process, and `StickyClients` keeps it for a minute. The burst costs under 100 ms of CPU and runs concurrently with the HTTP probes, so the scan stays inside its budget. It is spent only on a runtime that listens somewhere, that no connection or launcher names, that is busy (last scan's verdict, or a quarter of a core now), and that hasn't been watched for 30 s. The Settings diagnostics line gained `clients: <note>`: "2 connected, launcher", "caught 1 poller", "no client seen". The real test spawns `curl` against a listener in the test process and expects the catcher to return it with the test process as its parent.

Why the earlier two releases could not have worked, in hindsight: 1.0.5 (sticky) needs one sighting, and a 5 s sampler against a millisecond-lived client gets none; 1.0.6 (launcher) needs the app above the server, and launchd is. Both were reasoned from the first run's process tree, not measured against this one. The `ps` and `netstat` output the user pasted settled it in two lines. Not yet verified on the Mac: that the burst lands on a poll (a 1.2 s window every 30 s against an unknown poll interval; over a multi-minute generation the odds compound, and sticky memory keeps a catch for a minute).

Measured on the Mac with 1.0.7 running: after ten minutes of generation the diagnostics line still read `clients: no client seen`. The burst ran (sd-server was busy, listening, unnamed) and the helpers were born in its window; what never happened was the socket read. A curl-sized helper lives ten to twenty milliseconds, most of them in dyld, and its socket exists for the last one or two, so a 20 ms sampler that insists on reading the newborn's socket list while the connection is open reads it either before the connect or after the exit, almost every time. The 1.0.7 test hid this: its listener held the accepted connection open for 150 ms, which no real server does. The evidence that something was polling was in the `netstat` output all along, in a column the design ignored: the TIME_WAIT rows carry the pid of the process that closed them, and the kernel keeps those rows for 30 s after the process is gone.

## 1.0.8: the TCP table remembers the dead (5 Oct 2026)
The fix uses what survives a helper's death instead of racing it.

- **The kernel's TCP table.** `TCPTable` reads `net.inet.tcp.pcblist_n`, the sysctl netstat uses, readable without root. The buffer is an `xinpgen` header, then per connection a group of records (INPCB, SOCKET, RCVBUF, SNDBUF, STATS, TCPCB), each starting with a 32-bit length and kind and advanced by the length rounded up to 8, then an `xinpgen` trailer. The record structs are `#ifdef PRIVATE` in xnu and absent from the SDK, so the reader takes the fields at offsets derived from the struct definitions (all three are declared under `#pragma pack(4)`, so the 64-bit fields are 4-aligned: ports at 16/18 and the address slots at 48/64 of `xinpcb_n`, `t_state` at 36 of `xtcpcb_n`, `so_last_pid` and `so_e_pid` at 68/72 of `xsocket_n`); the layout is written out in `TCPTable.swift`. `so_last_pid` is the pid that last touched the socket: for a client connection, the client, and the kernel keeps the row in TIME_WAIT for 2 MSL after that client has exited. A synthetic buffer proves the chaining and the offsets against the documentation; the real test connects to its own listener, hangs up first, and finds its own pid on the closed connection.
- **The newborn ledger.** The burst no longer reads sockets at all. `PollerCatcher.watchNewborns` lists pids every 5 ms for 1.2 s and reads each newborn's bsdinfo once (parent, name, path); `NewbornLedger` keeps them for three minutes, a later birth of a reused pid replacing the earlier. The burst measures its own cost (its thread's CPU time, tick by tick) and the note shows it; the first CI run measured process-wide CPU instead and read 1.6 s, which was every suite running in parallel, not the burst.
- **Attribution.** Every scan reads the table once and takes the connections to the runtimes' ports (loopback, any state but listening) whose pid is not the runtime's, not this app's (its own probes leave TIME_WAIT rows too) and not a process already counted as connected. A live pid is chained through the process snapshot as before. A dead pid is walked up through the ledger (a `sh -c curl` wrapper is itself a newborn there, and is left out of the chain so it doesn't read as a terminal's shell) until a live ancestor, from which the usual chain runs; the result goes through the same `attribution` rules as a connection, so the server's own children are excluded, pids are counted once, and the main actor resolves the chain to the app and keeps it sticky for a minute. Nine helpers of one app are one poller: the note counts distinct parents.
- **The burst is evidence-based.** A runtime is watched iff the table shows a connection to its ports from a pid that is neither alive nor in the ledger, and it wasn't watched in the last 30 s. The busy heuristic no longer gates it, and `lastBusy` is gone. When a burst ran, the table is read again after it, so the helpers born during the burst are attributed in the same scan.
- **Diagnostics.** The clients note now says everything the next screenshot needs: `caught 1 poller (Qwen Image) · table: 11 to :1235, 9 dead, 3 in ledger · burst 16:16:40, 7 born, 23 ms` (the burst's own CPU cost, measured tick by tick on its thread). With nothing in the table and no burst, the 1.0.7 wording stands (`no client seen`, `2 connected, launcher`).

The end-to-end test spawns `curl` against a listener in the test process that answers and waits for curl to hang up (as a keep-alive server does; the client is the active closer, so its half of the connection is what stays), runs the burst meanwhile, waits for curl to exit, and then attributes the dead curl to the test process through the table and the ledger. Not verifiable on CI: the owner's helper tree (whether the pollers are direct children of Qwen Image or go through a shell), and whether a poll lands in a 1.2 s burst window; the diagnostics line will say.


## Where things stand (end of 2 Oct 2026)
**Origin.** GyozaVitals was #4 on a list of twelve project ideas built from the models already on the user's Mac (see `docs/PROJECT-IDEAS.md` in the GyozaIsland repo). It was picked first because it is small and because every other local-model project on the list would hit the same RAM collisions it makes visible.

**Verified on the user's 16 GB Mac (macOS 27):** models from sd.cpp, whisper.cpp and Ollama with correct names, sizes and devices; "used by" collapsed to the app name; one row per Ollama model with a live unload countdown; the memory bar and legend; "models resident"; headroom; pressure history; CPU with P/E split; GPU; thermal; power; the activity log seeded silently; the menu-bar glyph and number; the red dot on sd.cpp during a Metal generation (1.0.4); the Diagnostics pane.

**Not yet seen working:** Ollama's own red dot while a request runs (same heuristic, untested on a real run); koboldcpp, llama-server, LM Studio, ComfyUI and mflux detection (none running on the user's Mac that day); energy use over an hour; the P/E-core index assumption.

**Lessons.**
- The first real run found what no test could: the user's image app runs sd.cpp, not ComfyUI; Ollama's API names a model by its manifest digest while the runner holds the layer digest; helper processes own the sockets, not the app.
- A heuristic tuned from outside the app is a guess. The busy rule took three releases until the Diagnostics pane showed the actual number (0.004 against a 0.005 floor). Instrument first, then tune.
- Read-only was the right call for 1.0: the app ran beside a two-hour generation on a swapping machine and never got in its way.

**1.1 candidates, in order of value:** unload buttons behind a confirmation (Ollama `keep_alive: 0`); a notification when pressure goes critical while a model is executing; a 1024 px icon source; per-model attribution for Ollama once its API exposes it; SMC fans and watts.

## Working notes
- Work goes on `develop`; releases come from `main`.
- To release: run Actions › Build › Run workflow on `main` with `release_tag: vX.Y.Z`.
- To review a design change: push, fetch the build job's log, `python3 scripts/decode-snapshots.py <log> .snapshots/<name>`.
