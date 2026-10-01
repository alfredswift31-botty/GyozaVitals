# GyozaVitals development log

GyozaVitals is a macOS menu-bar monitor for local AI models: what's loaded, in which runtime, how much memory, used by which app, and the system load behind it.

## Releases

| Version | Date | Release |
|---|---|---|

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
- The AppIcon is GyozaYap's for now, as a placeholder; it needs its own.

## Working notes
- Work goes on `develop`; releases come from `main`.
- To release: run Actions › Build › Run workflow on `main` with `release_tag: vX.Y.Z`.
- To review a design change: push, fetch the build job's log, `python3 scripts/decode-snapshots.py <log> .snapshots/<name>`.
