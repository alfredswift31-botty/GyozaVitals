import SwiftUI

/// MODELS: one header row of labels, then a 44 pt row per loaded model,
/// flat, sorted by runtime then size. Scrolls only past eight rows. Under
/// the list, one quiet line for Apple Intelligence.
struct ModelsSection: View {
    let models: [LoadedModel]
    let appleIntelligenceAvailable: Bool?
    @Environment(\.frozenDate) private var frozenDate

    private var sorted: [LoadedModel] {
        let order = RuntimeKind.allCases
        return models.sorted { a, b in
            let ra = order.firstIndex(of: a.runtime) ?? order.count
            let rb = order.firstIndex(of: b.runtime) ?? order.count
            if ra != rb { return ra < rb }
            if a.sizeBytes != b.sizeBytes { return a.sizeBytes > b.sizeBytes }
            return a.name < b.name
        }
    }

    /// Only a row with an expiry needs the clock every second.
    private var tick: TimeInterval {
        models.contains { $0.expiresAt != nil } ? 1 : 60
    }

    var body: some View {
        PopoverSection("Models") {
            if models.isEmpty {
                empty
            } else {
                header
                TimelineView(.periodic(from: Date.now, by: tick)) { context in
                    list(now: frozenDate ?? context.date)
                }
            }
            Text(appleIntelligenceLine)
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.inkTertiary)
                .frame(height: Theme.Layout.textRow)
                .padding(.top, models.isEmpty ? 0 : Theme.Space.xs)
        }
    }

    private var header: some View {
        HStack {
            Text("Name").labelStyle()
            Spacer()
            Text("Size").labelStyle()
        }
        .frame(height: Theme.Layout.textRow)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func list(now: Date) -> some View {
        let rows = sorted
        let column = VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, model in
                ModelRow(model: model, now: now)
                    .overlay(alignment: .bottom) {
                        if index < rows.count - 1 { Hairline() }
                    }
            }
        }
        if rows.count > Theme.Layout.modelRowsBeforeScrolling {
            ScrollView(.vertical) { column }
                .frame(height: CGFloat(Theme.Layout.modelRowsBeforeScrolling) * Theme.Layout.modelRow)
        } else {
            column
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("nothing loaded").titleStyle()
            Text("Ollama, koboldcpp, llama-server, ComfyUI and whisper.cpp are watched.")
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.s)
    }

    private var appleIntelligenceLine: String {
        let state = switch appleIntelligenceAvailable {
        case .some(true): "available"
        case .some(false): "not available"
        case .none: "not observable"
        }
        return "Apple Intelligence · \(state)"
    }
}

/// Two lines in 44 pt: name and size; runtime · device · clients and state.
struct ModelRow: View {
    let model: LoadedModel
    let now: Date

    private var isUnloading: Bool { model.state == .unloading }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                if model.state == .executing {
                    LiveDot()
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                        .accessibilityHidden(true)
                }
                Text(model.name)
                    .font(Theme.Typeface.heading)
                    .strikethrough(isUnloading, color: Theme.inkTertiary)
                    .foregroundStyle(isUnloading ? Theme.inkTertiary : Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.s)
                Text(Formatting.bytes(model.sizeBytes))
                    .font(Theme.Typeface.mono)
                    .monospacedDigit()
                    .foregroundStyle(isUnloading ? Theme.inkTertiary : Theme.ink)
            }
            // Runtime · device and the state are sized first and never squeezed;
            // the client names take what is left and truncate at the tail.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(detail)
                    .font(Theme.Typeface.meta)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                if let clientsText {
                    Text(" · \(clientsText)")
                        .font(Theme.Typeface.meta)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Theme.Space.s)
                state
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .frame(height: Theme.Layout.modelRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(model.expiresAt != nil || model.state == .loading ? .updatesFrequently : [])
    }

    @ViewBuilder
    private var state: some View {
        switch model.state {
        case .loading:
            HStack(spacing: Theme.Space.xs) {
                ProgressView().controlSize(.small)
                Text("loading")
                    .font(Theme.Typeface.mono)
                    .foregroundStyle(Theme.inkSecondary)
            }
        case .unloading:
            Text("unloading")
                .font(Theme.Typeface.mono)
                .strikethrough(true, color: Theme.inkTertiary)
                .foregroundStyle(Theme.inkTertiary)
        case .idle, .executing:
            if let expiresAt = model.expiresAt {
                Text("unloads \(Formatting.countdown(to: expiresAt, from: now))")
                    .font(Theme.Typeface.mono)
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private var deviceWord: String? {
        switch model.device {
        case .gpu: "gpu"
        case .cpu: "cpu"
        case .split: "gpu/cpu"
        case .unknown: nil
        }
    }

    /// "ollama · gpu": the part of line 2 that always survives.
    private var detail: String {
        var parts = [model.runtime.displayName]
        if let deviceWord { parts.append(deviceWord) }
        return parts.joined(separator: " · ")
    }

    /// At most two client names, then "+N" for the rest: "GyozaYap, Flow +2".
    /// Nil when nobody is connected. The accessibility label lists them all.
    private var clientsText: String? {
        let names = model.clients.map(\.name)
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(Self.shownClients).joined(separator: ", ")
        let rest = names.count - Self.shownClients
        return rest > 0 ? "\(shown) +\(rest)" : shown
    }

    private static let shownClients = 2

    private var accessibilityText: String {
        var parts = [model.name, Formatting.bytes(model.sizeBytes), model.runtime.displayName]
        if let deviceWord { parts.append(deviceWord) }
        if !model.clients.isEmpty { parts.append("used by " + model.clients.map(\.name).joined(separator: ", ")) }
        switch model.state {
        case .loading: parts.append("loading")
        case .unloading: parts.append("unloading")
        case .executing: parts.append("executing")
        case .idle: break
        }
        if let expiresAt = model.expiresAt, model.state != .unloading {
            parts.append("unloads in \(Formatting.countdown(to: expiresAt, from: now))")
        }
        return parts.joined(separator: ", ")
    }
}
