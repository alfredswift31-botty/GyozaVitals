import SwiftUI

/// Settings: a grouped Form on the canvas, 520 pt wide. Menu bar content,
/// refresh rates, the runtimes to watch with their ports, open at login.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

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
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .frame(width: Theme.Layout.settingsWidth, height: Theme.Layout.settingsHeight)
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
