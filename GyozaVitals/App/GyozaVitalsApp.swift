import SwiftUI

@main
struct GyozaVitalsApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: VitalsStore

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: VitalsStore(settings: settings,
                                                       metrics: LiveSources.metrics(),
                                                       scanner: LiveSources.scanner()))
    }

    var body: some Scene {
        MenuBarExtra {
            VitalsPopover()
                .environmentObject(store)
                .environmentObject(settings)
                .onAppear { store.isPopoverOpen = true; if store.lastScan == nil { store.start() } }
                .onDisappear { store.isPopoverOpen = false }
        } label: {
            StatusItemLabel(modelBytes: store.modelBytes, modelCount: store.models.count,
                            content: settings.statusItemContent)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(store)
        }
    }
}
