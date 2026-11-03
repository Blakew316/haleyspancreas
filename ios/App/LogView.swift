import SwiftUI

struct LogView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false

    var body: some View {
        ZStack {
            AmbientBackground(color: Palette.high)
            VStack(alignment: .leading, spacing: Theme.spacing) {
                PageHeader(eyebrow: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()), title: "Log") {
                    GlassCircleButton(systemImage: "plus", prominent: true, size: 48, label: "Add meal") {
                        adding = true
                    }
                }
                .padding(.horizontal, 20)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if sections.isEmpty {
                            HStack(spacing: 12) {
                                Image(systemName: "fork.knife")
                                    .foregroundStyle(Palette.high)
                                Text("No meals yet")
                                    .font(.system(.body, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .card()
                        }
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Eyebrow(text: section.title)
                                    .padding(.leading, 6)
                                VStack(spacing: 0) {
                                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                                        LogRow(row: row)
                                            .padding(.vertical, 12)
                                            .contentShape(Rectangle())
                                            .contextMenu {
                                                Button(role: .destructive) {
                                                    Task { try? await model.deleteEntry(kind: row.kind.rawValue, id: row.id) }
                                                } label: {
                                                    Label("Delete", systemImage: "trash")
                                                }
                                            }
                                        if index < section.rows.count - 1 {
                                            Divider().opacity(0.4).padding(.leading, 48)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                                .liquidGlass(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.refresh() }
            }
        }
        .sheet(isPresented: $adding) {
            MealSheet().environmentObject(model)
        }
    }

    // MARK: Rows grouped by day

    private struct DaySection: Identifiable {
        let day: Date
        let rows: [LogRow.Model]
        var id: Date { day }
        var title: String {
            if Calendar.current.isDateInToday(day) { return "Today" }
            if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
            return day.formatted(.dateTime.weekday(.wide).month().day())
        }
    }

    private var sections: [DaySection] {
        guard let s = model.status else { return [] }
        let meals = s.carbs.map {
            LogRow.Model(id: $0.id, kind: .carbs, time: $0.time,
                         title: ($0.note?.isEmpty == false ? $0.note! : "Meal"),
                         amount: "\(Int($0.grams.rounded())) g")
        }
        let doses = s.insulin.map {
            LogRow.Model(id: $0.id, kind: .insulin, time: $0.time, title: "Bolus",
                         amount: "\($0.units.formatted(.number.precision(.fractionLength(0...2)))) u")
        }
        let pods = s.podChanges.map {
            LogRow.Model(id: $0.id, kind: .pod, time: $0.time, title: "New pod", amount: "")
        }
        let all = (meals + doses + pods).sorted { $0.time > $1.time }
        let grouped = Dictionary(grouping: all) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { DaySection(day: $0, rows: grouped[$0] ?? []) }
    }
}

struct LogRow: View {
    enum Kind: String {
        case insulin, carbs, pod

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

    struct Model: Identifiable {
        let id: String
        let kind: Kind
        let time: Double
        let title: String
        let amount: String
        var date: Date { Date(timeIntervalSince1970: time) }
    }

    let row: Model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: row.kind.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(row.kind.tint)
                .frame(width: 34, height: 34)
                .background(row.kind.tint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .lineLimit(1)
                Text(row.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.amount)
                .font(.system(.body, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The "+" pop-up: what she ate, and the carbs.
struct MealSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var meal = ""
    @State private var carbs = ""
    @State private var saving = false
    @State private var saved = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case meal, carbs }

    private var grams: Double? { Double(carbs.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        EntrySheet(title: "Add Meal", height: 300, canSave: (grams ?? 0) > 0, saving: saving, onSave: save) {
            VStack(spacing: 12) {
                TextField("Meal", text: $meal)
                    .font(.system(.title3, design: .rounded))
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.next)
                    .focused($focus, equals: .meal)
                    .onSubmit { focus = .carbs }
                    .modifier(FieldBackground())

                HStack(alignment: .firstTextBaseline) {
                    TextField("0", text: $carbs)
                        .font(Theme.numeral(34))
                        .keyboardType(.numberPad)
                        .focused($focus, equals: .carbs)
                    Text("g carbs")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .modifier(FieldBackground(height: 72))

                if let error {
                    Text(error).font(.footnote).foregroundStyle(Palette.low)
                }
            }
        }
        .onAppear { focus = .meal }
        .sensoryFeedback(.success, trigger: saved)
    }

    private func save() {
        guard let grams, grams > 0 else { return }
        saving = true
        let name = meal.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { saving = false }
            do {
                try await model.logCarbs(grams: grams, at: .now, note: name.isEmpty ? nil : name)
                saved = true
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
