import SwiftUI
import Testing
@testable import GyozaVitals

/// Every screen, light and dark. CI prints the PNGs so a design change is
/// reviewed from the log (see scripts/decode-snapshots.py).
@MainActor
@Suite(.serialized)
struct UISnapshotTests {
    private static let width = Theme.Layout.popoverWidth

    /// The popover on a canvas that fills the frame, with the clock frozen at
    /// the fixtures' "now" so countdowns are stable.
    private static func popover(_ store: VitalsStore, pressure: [MemoryPressure?]) -> some View {
        VitalsPopover(pressureHistory: PressureHistory(seed: pressure))
            .environmentObject(store)
            .environmentObject(store.settings)
            .environment(\.frozenDate, Fixtures.now)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.canvas)
    }

    @Test(arguments: [false, true])
    func popoverBusy(dark: Bool) throws {
        let store = Fixtures.busyStore()
        try Snapshot.render(Self.popover(store, pressure: Fixtures.busyPressure),
                            name: "01-popover-busy", size: CGSize(width: Self.width, height: 800), dark: dark)
    }

    @Test(arguments: [false, true])
    func popoverQuiet(dark: Bool) throws {
        let store = Fixtures.quietStore()
        try Snapshot.render(Self.popover(store, pressure: Fixtures.quietPressure),
                            name: "02-popover-quiet", size: CGSize(width: Self.width, height: 620), dark: dark)
    }

    @Test(arguments: [false, true])
    func settings(dark: Bool) throws {
        let store = Fixtures.quietStore()
        try Snapshot.render(SettingsView().environmentObject(store.settings).environmentObject(store),
                            name: "03-settings", size: CGSize(width: Theme.Layout.settingsWidth, height: Theme.Layout.settingsHeight), dark: dark)
    }

    /// Memory pressure critical, thermal critical, a model executing, one loading, one unloading.
    @Test(arguments: [false, true])
    func popoverCritical(dark: Bool) throws {
        let store = Fixtures.criticalStore()
        try Snapshot.render(Self.popover(store, pressure: Fixtures.criticalPressure),
                            name: "04-popover-critical", size: CGSize(width: Self.width, height: 760), dark: dark)
    }

    /// One model, no clients, no GPU figures, on battery and charging.
    @Test(arguments: [false, true])
    func popoverSingle(dark: Bool) throws {
        let store = Fixtures.singleStore()
        try Snapshot.render(Self.popover(store, pressure: Fixtures.quietPressure),
                            name: "05-popover-single", size: CGSize(width: Self.width, height: 620), dark: dark)
    }

    /// The status item in its three settings, on the window background the bar would give it.
    @Test(arguments: [false, true])
    func statusItem(dark: Bool) throws {
        let row = HStack(spacing: Theme.Space.xl) {
            StatusItemLabel(modelBytes: 0, modelCount: 0, content: .modelMemory)
            StatusItemLabel(modelBytes: 27_400_000_000, modelCount: 5, content: .modelCount)
            StatusItemLabel(modelBytes: 27_400_000_000, modelCount: 5, content: .modelMemory)
            StatusItemLabel(modelBytes: 1_300_000_000, modelCount: 1, content: .modelMemory)
        }
        .padding(Theme.Space.s)
        .scaleEffect(3, anchor: .topLeading)
        try Snapshot.render(row, name: "06-status-item", size: CGSize(width: 720, height: 110), dark: dark)
    }
}
