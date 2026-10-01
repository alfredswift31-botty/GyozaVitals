import SwiftUI
import Testing
@testable import GyozaVitals

/// Every screen, light and dark. CI prints the PNGs so a design change is
/// reviewed from the log (see scripts/decode-snapshots.py).
@MainActor
@Suite(.serialized)
struct UISnapshotTests {
    private static let popover = CGSize(width: 340, height: 640)

    @Test(arguments: [false, true])
    func popoverBusy(dark: Bool) throws {
        let store = Fixtures.busyStore()
        try Snapshot.render(VitalsPopover().environmentObject(store).environmentObject(store.settings),
                            name: "01-popover-busy", size: Self.popover, dark: dark)
    }

    @Test(arguments: [false, true])
    func popoverQuiet(dark: Bool) throws {
        let store = Fixtures.quietStore()
        try Snapshot.render(VitalsPopover().environmentObject(store).environmentObject(store.settings),
                            name: "02-popover-quiet", size: Self.popover, dark: dark)
    }

    @Test(arguments: [false, true])
    func settings(dark: Bool) throws {
        let store = Fixtures.quietStore()
        try Snapshot.render(SettingsView().environmentObject(store.settings).environmentObject(store),
                            name: "03-settings", size: CGSize(width: 520, height: 560), dark: dark)
    }
}
