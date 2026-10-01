import AppKit
import Combine
import SwiftUI

/// The menu-bar window: 340 pt wide, canvas to the edge, sections separated
/// by `SectionLabel` only, in the order MODELS, MEMORY, PROCESSOR, POWER,
/// ACTIVITY, then a footer. Height depends on the number of model rows and
/// nothing else, so a tick never moves the content.
struct VitalsPopover: View {
    @EnvironmentObject private var store: VitalsStore
    @StateObject private var pressureHistory: PressureHistory

    /// Pass a seeded history for previews and snapshots; the app shares one
    /// across openings of the window.
    init(pressureHistory: PressureHistory? = nil) {
        _pressureHistory = StateObject(wrappedValue: pressureHistory ?? PressureHistory.live)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ModelsSection(models: store.models, appleIntelligenceAvailable: store.appleIntelligenceAvailable)
                MemorySection(memory: store.system?.memory, modelBytes: store.modelBytes, history: pressureHistory)
                ProcessorSection(cpu: store.system?.cpu, gpu: store.system?.gpu, thermal: store.system?.thermal)
                PowerSection(power: store.system?.power)
                ActivitySection(events: store.events)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.l)
            PopoverFooter()
        }
        .frame(width: Theme.Layout.popoverWidth, alignment: .leading)
        .background(Theme.canvas)
        .onAppear { pressureHistory.attach(to: store) }
    }
}

/// A section: its label on a 20 pt row, then the content, 8 pt below.
struct PopoverSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(title).frame(height: Theme.Layout.labelRow)
            content()
        }
    }
}

/// Settings… and Quit as plain text under an edge-to-edge hairline.
private struct PopoverFooter: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack {
                Button("Settings…") {
                    NSApplication.shared.activate()
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.plain)
            .font(Theme.Typeface.meta)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, Theme.Space.l)
            .frame(height: Theme.Layout.footerRow)
        }
    }
}

/// The last sixty memory-pressure levels the store reported, for the strip.
/// One sample per metrics tick; the app's one instance outlives the window.
@MainActor
final class PressureHistory: ObservableObject {
    static let live = PressureHistory()

    @Published private(set) var samples: [MemoryPressure?]
    private var subscription: AnyCancellable?

    init(seed: [MemoryPressure?] = []) {
        samples = Array(seed.suffix(Theme.Gauge.stripSamples))
    }

    func record(_ pressure: MemoryPressure?) {
        samples.append(pressure)
        if samples.count > Theme.Gauge.stripSamples {
            samples.removeFirst(samples.count - Theme.Gauge.stripSamples)
        }
    }

    /// Follow the store's system snapshots. Attaching twice is a no-op.
    func attach(to store: VitalsStore) {
        guard subscription == nil else { return }
        subscription = store.$system
            .dropFirst()
            .sink { [weak self] snapshot in self?.record(snapshot?.memory.pressure) }
        record(store.system?.memory.pressure)
    }
}

/// A fixed "now" for previews and snapshots, so countdowns render the same
/// every time. Nil in the app: the clock runs.
nonisolated struct FrozenDateKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    var frozenDate: Date? {
        get { self[FrozenDateKey.self] }
        set { self[FrozenDateKey.self] = newValue }
    }
}
