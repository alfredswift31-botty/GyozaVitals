import SwiftUI

/// ACTIVITY: the last five events, time then text. The block keeps the
/// height of five rows whether it holds none or five.
struct ActivitySection: View {
    let events: [ActivityEvent]

    private var recent: [ActivityEvent] { Array(events.prefix(Theme.Layout.activityRows)) }

    /// A two-digit hour in the user's clock format, so the time column holds
    /// still whatever the hour: "22:58" or "10:58 PM" in mono.
    private static let widestClock: String = {
        let late = Calendar.current.date(bySettingHour: 22, minute: 58, second: 0, of: Date()) ?? Date()
        return Formatting.clock(late)
    }()

    private static var blockHeight: CGFloat {
        CGFloat(Theme.Layout.activityRows) * Theme.Layout.textRow + CGFloat(Theme.Layout.activityRows - 1) * Theme.Space.xs
    }

    var body: some View {
        PopoverSection("Activity") {
            Group {
                if recent.isEmpty {
                    Text("no activity yet")
                        .font(Theme.Typeface.meta)
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(height: Theme.Layout.textRow)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(recent) { event in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                                ZStack(alignment: .leading) {
                                    Text(Self.widestClock).hidden()
                                    Text(Formatting.clock(event.date))
                                }
                                .font(Theme.Typeface.mono)
                                .monospacedDigit()
                                .foregroundStyle(Theme.inkTertiary)
                                Text(event.text)
                                    .font(Theme.Typeface.meta)
                                    .foregroundStyle(color(for: event.kind))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(height: Theme.Layout.textRow)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .frame(height: Self.blockHeight, alignment: .top)
        }
    }

    private func color(for kind: ActivityKind) -> Color {
        switch kind {
        case .pressureCritical: Theme.live
        case .evicted, .thermal: Theme.ink
        case .loaded, .unloaded, .runtimeStarted, .runtimeStopped, .pressureWarning: Theme.inkSecondary
        }
    }
}
