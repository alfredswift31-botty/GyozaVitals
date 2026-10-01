import SwiftUI

/// Placeholder so the scaffold builds; the UI module replaces this file.
struct VitalsPopover: View {
    @EnvironmentObject private var store: VitalsStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionLabel("Models")
            if store.models.isEmpty {
                Text("nothing loaded").titleStyle()
            } else {
                ForEach(store.models) { model in
                    Text(model.name).font(Theme.Typeface.heading)
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 340, alignment: .leading)
        .background(Theme.canvas)
    }
}

/// Placeholder; the UI module replaces this file.
struct StatusItemLabel: View {
    let modelBytes: UInt64
    let modelCount: Int
    let content: StatusItemContent

    var body: some View {
        switch content {
        case .iconOnly: Image(systemName: "waveform.path.ecg")
        case .modelCount: Label("\(modelCount)", systemImage: "waveform.path.ecg")
        case .modelMemory: Label(Formatting.compactBytes(modelBytes), systemImage: "waveform.path.ecg")
        }
    }
}

/// Placeholder; the UI module replaces this file.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $settings.openAtLogin)
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}
