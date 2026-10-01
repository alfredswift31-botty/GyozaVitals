# GyozaVitals

A macOS menu-bar utility that shows which local AI models are loaded on your Mac right now, in which runtime, how much memory they take, which app is using them, and the system load behind them. It watches Ollama, koboldcpp, llama-server, LM Studio, whisper.cpp, ComfyUI, mflux and stable-diffusion.cpp by reading the operating system, so it works whether or not a runtime has an API.

Read-only. It never loads, unloads or interrupts anything.

## What it shows
- **Models:** name, size, runtime, GPU or CPU, the apps connected to it, and its state: loading, idle, executing (the one red dot), or the countdown until Ollama unloads it.
- **Memory:** app, wired, compressed and cached, with the models' share, memory pressure, swap, and headroom: how much more you could load before pressure.
- **Processor:** CPU with the performance / efficiency-core split, GPU utilisation and memory where macOS reports them, thermal state.
- **Power:** battery or adapter, charging, Low Power Mode.
- **Activity:** a log of loads, unloads, evictions and pressure changes with times, so "why was it slow at 14:02" has an answer.

## What it can't show
Without root or private frameworks there is no CPU frequency, no Neural Engine utilisation, no per-component watts, and no view into Apple Intelligence's own model (its daemons run as root). GyozaVitals says "not observable" rather than guessing.

## Requirements
macOS 15 or later on Apple silicon. Not sandboxed (reading other processes needs it), hardened runtime, ad-hoc signed.

## Install
Download `GyozaVitals.zip` from the latest release, unzip, move to Applications, open. It lives in the menu bar; there's no Dock icon. Open at login is in Settings.

## Development
`docs/PLAN.md` is the architecture; `docs/DESIGN.md` the visual contract; `docs/DEVELOPMENT_LOG.md` the history. CI builds on macOS 26, runs the tests, renders every screen in light and dark and prints the images into the log; `scripts/decode-snapshots.py <log> <dir>` recovers them.
