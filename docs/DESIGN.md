# GyozaVitals design

The same Swiss / typographic language as GyozaYap (`Theme.swift` is shared), applied to a dense utility. The taste-skill's density rule is the only part of it that applies here: no card boxes, 1 px lines separate data, mono for all numbers. Everything else in a monitor tempts you toward a dashboard; this document is mostly a list of things not to do.

**Dials:** variance 5, motion 2, density 7.

## Principles
1. **Type is the design.** San Francisco and SF Mono. Hierarchy by size and weight. No icons before values; the label says what it is.
2. **Monochrome.** `Theme.canvas`, `ink`, `inkSecondary`, `inkTertiary`, `hairline`, `wash`, `surface`. **The one red (`Theme.live`) means "executing right now"** (a model serving a request) or "critical" (memory pressure, thermal). Never for emphasis.
3. **Hairlines, not cards.** Sections are separated by `SectionLabel` only. No tiles, no boxes, no shadows, no glass inside the popover. The system keeps its own rim and corner radius; the content fills to the edge on `Theme.canvas`.
4. **One visual per section.** Memory gets one stacked bar and one pressure strip. CPU, GPU and thermal are numbers. If it can be said with a number, don't draw it.
5. **Numbers never jitter.** `.monospacedDigit()` on every value, fixed-width numeric columns, right-aligned. CPU and GPU smoothed and whole-percent; memory to one decimal GB. The displayed total is computed from the displayed parts.
6. **Both appearances,** and both menu-bar styles on macOS 26 (Clear and Tinted glass) for the status glyph.

## Measurements
- Popover width **340 pt**; horizontal padding 16 (`Theme.Space.l`), not GyozaYap's 40 pt page margin. Content column 308 pt.
- 4 pt vertical rhythm. `SectionLabel` row 20 pt. Model row **44 pt** (two lines). Bar 6 pt. Section gap 16.
- Four label-over-value columns = 4 × 77 pt.
- Type: 13.5 semibold for model names; 12 for values; 10.5 bold uppercase, tracking 0.8, for labels; 11.5 mono for sizes, ports, timers and percentages. The only large type is the empty state's one word at 28 pt (`Theme.Typeface.title`), lowercase: `nothing loaded`.

## Components (in `Theme.swift` unless noted)
- `MetaPair` — label over value. The legend rows.
- `MemorySection` (`Views/`) — the stacked bar; a legend of **exactly the bar's parts plus the remainder**: APP / WIRED / COMPR. / FREE, four equal 77 pt columns, values mono (the full word COMPRESSED needs about 82 pt at label size and would clip, so it is abbreviated rather than given an uneven column); the pressure strip; then two fixed 16 pt rows. Row 1 is the status (headroom while normal, else `warning` / `critical`). Row 2 is a quiet meta line in `inkTertiary`, mono digits, for what the bar cannot show: `models resident 6.0 GB · swap 4.5 GB`. "models resident" is the runtimes' footprint (only pages actually touched, so a freshly mapped file reads small until it is used), which overlaps APP and WIRED (on Apple silicon GPU buffers count as wired), so it is never a legend column; swap is disk, not RAM, so neither is it. The swap part is omitted when swap is 0; with no model memory and no swap the row reads `no model memory`. Both rows are always present so a tick never moves the popover.
- `SectionLabel` — small bold uppercase with a hairline running right.
- `Meter` (new) — a 6 pt bar: track `Theme.wash`, fill `Theme.ink`, radius 0, hairline ticks at 25/50/75 %. Stacked variant: fills at ink 100 % / 55 % / 25 % separated by 1 pt of canvas, plus a `live` segment only when the section is critical.
- `PressureStrip` (new) — 60 samples × 5 pt, 4 pt tall; ink opacity maps to pressure; `live` fill while critical.
- `LiveDot` — 9 pt; only on an executing model row; breathes unless Reduce Motion.
- `KeyCap` — not used in the popover.

## The model row
```
qwen3-vl:8b                                   6.1G
ollama · gpu · GyozaYap, Flow        unloads 4:12
```
Line 1: name in 13.5 semibold, size right-aligned in mono. Line 2: runtime · device · client app names in `inkTertiary` 12 pt; at most two names, then `+N` for the rest (`GyozaYap, Flow +2`). On the right, the state in mono: `loading` (with a small `ProgressView`), nothing when idle, `unloads 4:12` when Ollama has an expiry, `unloading` struck through. Runtime · device and the state have layout priority and never truncate; only the client names do, at the tail. The row's accessibility label still lists every client. A `LiveDot` sits before the name only while executing. One header row of labels (NAME / SIZE) above the list, not per row.

## States
- **Loading:** `inkSecondary` text plus `ProgressView().controlSize(.small)`.
- **Executing:** `LiveDot`, name in ink.
- **Idle:** plain ink.
- **Unloading / evicted:** `inkTertiary`, name struck through with a hairline.
- **Runtime off:** not shown; the settings screen lists which runtimes are watched.
- **Unknown value:** an en dash, never 0.
- **Memory pressure:** normal = nothing said; warning = the word `warning` in `inkSecondary`; critical = the word in `live` and the strip's last samples in `live`.

## Copy
Sentence case except labels. Short and specific. Empty state: `nothing loaded` and one meta line: "Ollama, koboldcpp, llama-server, ComfyUI and whisper.cpp are watched." No emoji, no exclamation marks.

## Status item
Template glyph, 18 × 18 pt, alpha only, 1.5 pt stroke: a gyoza half-moon with three 1 pt pleat ticks over a short baseline. Beside it, when anything is loaded, one mono number such as `12.4G` in `NSFont.monospacedDigitSystemFont(ofSize: 12)`, in a fixed-width slot sized for `99.9G` so the bar never reflows. Never a sparkline in the bar.

## Settings
GyozaYap's precedent: grouped `Form`, `.scrollContentBackground(.hidden)`, `Theme.canvas` background, 520 pt wide, headers in `labelStyle()`, footers in `Theme.Typeface.meta`.

## Accessibility and motion
Each model row is one accessibility element (`children: .combine`) that reads name, size, runtime, device, apps and state. Bars carry an `accessibilityValue` ("Memory 12.4 of 32 gigabytes, pressure normal"). Live numbers are `.updatesFrequently`. Under Reduce Motion: no numeric transitions, no breathing dot, no strip animation.

## Guardrails (do not break)
- No raw colours, font sizes or radii in views: tokens only.
- No icons in the popover except the system glyph in the status item and SF Symbols in Settings where the Form expects them.
- The popover's height is fixed for a given number of model rows; it must not grow or shrink on a tick.
- Keep the snapshot entry points: every view takes its data from `VitalsStore` or plain values so `UISnapshotTests` can render it with fixtures.
