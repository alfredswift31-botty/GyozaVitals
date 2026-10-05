import SwiftUI

/// Settings: a grouped Form on the canvas, 520 pt wide. Menu bar content,
/// refresh rates, the runtimes to watch with their ports, open at login, and
/// a diagnostics section showing what the busy heuristic saw per runtime.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: VitalsStore
    /// The window's height; the snapshot test passes the Form's full
    /// content height so the diagnostics lines can be reviewed.
    let height: CGFloat

    init(height: CGFloat = Theme.Layout.settingsHeight) {
        self.height = height
    }

    private static let runtimes: [RuntimeKind] = RuntimeKind.allCases.filter { $0 != .appleIntelligence && $0 != .unknown }

    var body: some View {
        Form {
            Section {
                Picker("Show", selection: $settings.statusItemContent) {
                    ForEach(StatusItemContent.allCases, id: \.self) { content in
                        Text(content.title).tag(content)
                    }
                }
            } header: {
                Text("Menu bar").labelStyle()
            }

            Section {
                Picker("While open", selection: $settings.openMetricsInterval) {
                    Text("1 s").tag(1.0 as TimeInterval)
                    Text("2 s").tag(2.0 as TimeInterval)
                    Text("5 s").tag(5.0 as TimeInterval)
                }
                Picker("While closed", selection: $settings.closedMetricsInterval) {
                    Text("15 s").tag(15.0 as TimeInterval)
                    Text("30 s").tag(30.0 as TimeInterval)
                    Text("60 s").tag(60.0 as TimeInterval)
                }
            } header: {
                Text("Refresh").labelStyle()
            } footer: {
                Text("System metrics at these rates; runtimes are probed every \(Int(settings.openScanInterval)) s while the window is open and every \(Int(settings.closedScanInterval)) s while it is closed.")
                    .font(Theme.Typeface.meta)
                    .foregroundStyle(Theme.inkSecondary)
            }

            Section {
                ForEach(Self.runtimes, id: \.self) { kind in
                    RuntimeRow(kind: kind, watched: watched(kind), port: port(kind))
                }
            } header: {
                Text("Runtimes").labelStyle()
            } footer: {
                Text("A runtime that is off is simply not shown. Ports tell GyozaVitals where to ask each runtime what it has loaded.")
                    .font(Theme.Typeface.meta)
                    .foregroundStyle(Theme.inkSecondary)
            }

            Section {
                Toggle("Open at login", isOn: $settings.openAtLogin)
            } header: {
                Text("General").labelStyle()
            } footer: {
                Text("GyozaVitals only reads. It never loads or unloads a model.")
                    .font(Theme.Typeface.meta)
                    .foregroundStyle(Theme.inkSecondary)
            }

            Section {
                ForEach(store.runtimes) { runtime in
                    DiagnosticsLine(text: Self.diagnosticsLine(runtime))
                }
                DiagnosticsLine(text: Self.scanLine(lastScan: store.lastScan, modelCount: store.models.count))
            } header: {
                Text("Diagnostics").labelStyle()
            } footer: {
                Text("What the busy heuristic sees. Share a screenshot of this when a red dot is missing or wrong.")
                    .font(Theme.Typeface.meta)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .frame(width: Theme.Layout.settingsWidth, height: height)
    }

    private static let dash = "\u{2013}"

    /// "sd.cpp pid 1234 · api: no api · cpu 0.012 · gpu 1.00 · candidate · decided by gpu · clients: caught 1 poller".
    static func diagnosticsLine(_ runtime: RuntimeInstance) -> String {
        let d = runtime.diagnostics
        let candidate = d.map { $0.candidate ? "candidate" : "not a candidate" } ?? "candidate \(dash)"
        return [
            "\(runtime.kind.displayName) pid \(runtime.pid)",
            "api: \(runtime.probeNote ?? dash)",
            "cpu \(Formatting.fraction(d?.cpuShare, decimals: 3))",
            "gpu \(Formatting.fraction(d?.gpuUtilization, decimals: 2))",
            candidate,
            "decided by \(d?.decidedBy ?? dash)",
            "clients: \(runtime.attributionNote ?? dash)",
        ].joined(separator: " · ")
    }

    /// "last scan 14:02:37 · 5 models".
    static func scanLine(lastScan: Date?, modelCount: Int) -> String {
        let when = lastScan.map(Formatting.clockWithSeconds) ?? dash
        return "last scan \(when) · \(modelCount) \(modelCount == 1 ? "model" : "models")"
    }

    private func watched(_ kind: RuntimeKind) -> Binding<Bool> {
        Binding(
            get: { settings.watchedRuntimes.contains(kind) },
            set: { on in
                if on { settings.watchedRuntimes.insert(kind) } else { settings.watchedRuntimes.remove(kind) }
            })
    }

    private func port(_ kind: RuntimeKind) -> Binding<Int> {
        Binding(
            get: { settings.ports[kind] ?? kind.defaultPort ?? 0 },
            set: { settings.ports[kind] = $0 })
    }
}

/// One runtime: its toggle and, when it listens on a port, the port field.
private struct RuntimeRow: View {
    let kind: RuntimeKind
    @Binding var watched: Bool
    @Binding var port: Int

    var body: some View {
        HStack {
            Toggle(kind.displayName, isOn: $watched)
            if kind.defaultPort != nil {
                TextField("Port", value: $port, format: IntegerFormatStyle<Int>().grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.Typeface.mono)
                    .frame(width: Theme.Layout.column)
                    .disabled(!watched)
                    .accessibilityLabel("\(kind.displayName) port")
            }
        }
    }
}

/// One mono line of the diagnostics section; wraps rather than truncates.
private struct DiagnosticsLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typeface.mono)
            .foregroundStyle(Theme.inkSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
