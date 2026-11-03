import SwiftUI

enum LogKind: String, Identifiable {
    case insulin, carbs, pod
    var id: String { rawValue }

    var title: String {
        switch self {
        case .insulin: return "Bolus"
        case .carbs: return "Carbs"
        case .pod: return "Pod change"
        }
    }

    var symbol: String {
        switch self {
        case .insulin: return "drop.fill"
        case .carbs: return "fork.knife"
        case .pod: return "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .insulin: return Palette.accent
        case .carbs: return Palette.high
        case .pod: return Palette.inRange
        }
    }
}

struct LogView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sheet: LogKind?

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground(color: Palette.accent)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacing) {
                        Text("Log").font(Theme.title(40)).padding(.top, 12)
                        Text("Omnipod 5 doesn't share its data, so log doses and pod changes here. They feed the insulin on board estimate and the pod countdown.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            ForEach([LogKind.insulin, .carbs, .pod]) { kind in
                                Button { sheet = kind } label: { LogTile(kind: kind) }
                                    .buttonStyle(.plain)
                            }
                        }

                        Eyebrow(text: "Recent").padding(.top, 12)
                        history
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $sheet) { kind in
                LogEntrySheet(kind: kind)
                    .presentationDetents([.medium])
                    .presentationCornerRadius(32)
            }
        }
    }

    private struct Row: Identifiable {
        let id: String
        let kind: LogKind
        let time: Double
        let text: String
    }

    private var rows: [Row] {
        guard let s = model.status else { return [] }
        let insulin = s.insulin.map { Row(id: $0.id, kind: .insulin, time: $0.time, text: "\($0.units.formatted(.number.precision(.fractionLength(0...2)))) u") }
        let carbs = s.carbs.map { Row(id: $0.id, kind: .carbs, time: $0.time, text: "\(Int($0.grams)) g") }
        let pods = s.podChanges.map { Row(id: $0.id, kind: .pod, time: $0.time, text: "New pod") }
        return (insulin + carbs + pods).sorted { $0.time > $1.time }
    }

    @ViewBuilder
    private var history: some View {
        if rows.isEmpty {
            Text("Nothing logged yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .card()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 14) {
                        Image(systemName: row.kind.symbol)
                            .font(.footnote)
                            .foregroundStyle(row.kind.tint)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(row.kind.tint.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.text).font(.system(.body, design: .rounded).weight(.medium))
                            Text(Date(timeIntervalSince1970: row.time).formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { try? await model.deleteEntry(kind: row.kind.rawValue, id: row.id) }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("Options for \(row.kind.title)")
                    }
                    .padding(.vertical, 10)
                    if index < rows.count - 1 { Divider().opacity(0.5) }
                }
            }
            .card(padding: 14)
        }
    }
}

private struct LogTile: View {
    let kind: LogKind
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: kind.symbol)
                .font(.title3.weight(.light))
                .foregroundStyle(kind.tint)
            Text(kind.title)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.primary)
        }
        .card(padding: 16)
        .contentShape(Rectangle())
    }
}

struct LogEntrySheet: View {
    let kind: LogKind
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var date = Date.now
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false
    @FocusState private var focused: Bool

    private var value: Double? { Double(amount.replacingOccurrences(of: ",", with: ".")) }
    private var canSave: Bool { kind == .pod || (value ?? 0) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(kind.title).font(Theme.title(28))
                Spacer()
                Button("Cancel") { dismiss() }.foregroundStyle(.secondary)
            }

            if kind != .pod {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("0", text: $amount)
                        .font(Theme.numeral(64))
                        .keyboardType(.decimalPad)
                        .focused($focused)
                        .fixedSize()
                    Text(kind == .insulin ? "units" : "grams")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Starts the 72-hour countdown shown on the Live Activity.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            DatePicker("Time", selection: $date, in: Date.now.addingTimeInterval(-7 * 86400)...Date.now)
                .font(.system(.body, design: .rounded))

            if let error {
                Text(error).font(.footnote).foregroundStyle(Palette.low)
            }

            Spacer(minLength: 0)

            Button {
                Task { await save() }
            } label: {
                Text(saving ? "Saving…" : "Save")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(kind.tint)
            .controlSize(.large)
            .disabled(!canSave || saving)
        }
        .padding(24)
        .onAppear { focused = kind != .pod }
        .sensoryFeedback(.success, trigger: saved)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            switch kind {
            case .insulin: try await model.logInsulin(units: value ?? 0, at: date, note: nil)
            case .carbs: try await model.logCarbs(grams: value ?? 0, at: date, note: nil)
            case .pod: try await model.logPodChange(at: date)
            }
            saved = true
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
