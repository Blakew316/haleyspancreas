import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var hours = 3
    @State private var sheet: QuickLog?

    enum QuickLog: String, Identifiable {
        case bolus, pod
        var id: String { rawValue }
    }

    private var status: ServerStatus? { model.status }

    var body: some View {
        let accent = rangeColor
        ZStack {
            AmbientBackground(color: accent)
            // Fixed layout, no scrolling: the chart takes whatever height is left on this iPhone.
            VStack(alignment: .leading, spacing: Theme.spacing) {
                PageHeader(eyebrow: Date.now.greeting, title: "Haley") {
                    if !(status?.activeAlerts.isEmpty ?? true) || status?.snoozeUntil != nil {
                        snoozeMenu
                    }
                }
                hero(color: accent)
                if let warning = serverWarning { WarningCard(message: warning) }
                chartCard
                GlassGroup {
                    HStack(spacing: Theme.spacing) {
                        Button { sheet = .bolus } label: { insulinCard }
                            .buttonStyle(.plain)
                        Button { sheet = .pod } label: { podCard }
                            .buttonStyle(.plain)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .bolus: BolusSheet().environmentObject(model)
            case .pod: PodSheet().environmentObject(model)
            }
        }
    }

    // MARK: Header and hero

    private var snoozeMenu: some View {
        Menu {
            Button("30 minutes") { snooze(30) }
            Button("1 hour") { snooze(60) }
            Button("2 hours") { snooze(120) }
            if status?.snoozeUntil != nil {
                Button("Resume alerts", role: .destructive) { snooze(0) }
            }
        } label: {
            Image(systemName: status?.snoozeUntil != nil ? "moon.zzz.fill" : "moon.zzz")
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .liquidGlass(Circle(), interactive: true)
        }
        .accessibilityLabel("Snooze alerts")
    }

    private var rangeColor: Color {
        guard let latest = status?.latest, let s = status?.settings else { return Palette.inRange }
        if isStale { return Palette.stale }
        return Glucose.color(latest.mgdl, low: s.low, high: s.high)
    }

    private var isStale: Bool {
        guard let latest = status?.latest else { return true }
        return Date.now.timeIntervalSince(latest.date) > 11 * 60
    }

    @ViewBuilder
    private func hero(color: Color) -> some View {
        if let latest = status?.latest, let settings = status?.settings {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 16) {
                    Text(Glucose.format(latest.mgdl, unit: settings.unit))
                        .font(Theme.numeral(92))
                        .foregroundStyle(color)
                        .contentTransition(.numericText(value: latest.mgdl))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    TrendBadge(trend: latest.trend, color: color)
                }
                HStack(spacing: 10) {
                    Text(Glucose.unitLabel(settings.unit))
                    if let d = status?.delta {
                        Text("·")
                        Text(Glucose.formatDelta(d, unit: settings.unit))
                    }
                    Text("·")
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(isStale ? "No recent reading" : ageText(latest.date))
                            .foregroundStyle(isStale ? Palette.low : .secondary)
                    }
                }
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Glucose.format(latest.mgdl, unit: settings.unit)) \(Glucose.unitLabel(settings.unit)), \(Glucose.trendDescription(latest.trend))")
            .animation(.smooth, value: latest.mgdl)
        } else {
            Text("—")
                .font(Theme.numeral(92))
                .foregroundStyle(.tertiary)
        }
    }

    private func ageText(_ date: Date) -> String {
        let minutes = Int(Date.now.timeIntervalSince(date) / 60)
        return minutes < 1 ? "Just now" : "\(minutes) min ago"
    }

    private var serverWarning: String? {
        if let e = status?.server.lastError { return "Can't reach Dexcom: \(e)" }
        if let e = model.lastError { return e }
        return nil
    }

    // MARK: Chart

    private var chartCard: some View {
        VStack(spacing: 14) {
            Picker("Range", selection: $hours) {
                Text("3h").tag(3)
                Text("6h").tag(6)
                Text("12h").tag(12)
                Text("24h").tag(24)
            }
            .pickerStyle(.segmented)
            GlucoseChart(
                readings: (status?.readings ?? []).filter { Date.now.timeIntervalSince($0.date) <= Double(hours) * 3600 },
                insulin: status?.insulin ?? [],
                settings: status?.settings,
                hours: hours
            )
            .frame(minHeight: 110, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .card()
    }

    // MARK: Small cards (tap to log)

    private var insulinCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeading(title: "Insulin")
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.1f", status?.iob ?? 0))
                    .font(Theme.numeral(32))
                Text("u").font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(interactive: true)
        .accessibilityLabel("Insulin on board \(String(format: "%.1f", status?.iob ?? 0)) units. Log a bolus.")
    }

    private var podCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeading(title: "Pod")
            if let pod = status?.pod {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let total = pod.expiresAt - pod.changedAt
                    let left = max(0, pod.expiresAt - context.date.timeIntervalSince1970)
                    HStack(spacing: 12) {
                        PodRing(progress: total > 0 ? left / total : 0)
                            .frame(width: 26, height: 26)
                        Text(left > 0 ? "\(Int(left / 3600))h" : "Expired")
                            .font(Theme.numeral(left > 0 ? 32 : 24))
                            .foregroundStyle(left > 0 ? Color.primary : Palette.low)
                    }
                }
            } else {
                Text("—").font(Theme.numeral(32)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(interactive: true)
        .accessibilityLabel("Pod. Log a pod change.")
    }

    private func snooze(_ minutes: Int) {
        Task { try? await model.snooze(minutes: minutes) }
    }
}

// MARK: - Components

private struct CardHeading: View {
    let title: String
    var body: some View {
        HStack {
            Eyebrow(text: title)
            Spacer()
            Image(systemName: "plus")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
    }
}

struct TrendBadge: View {
    let trend: String
    let color: Color
    var body: some View {
        Text(Glucose.arrow(trend))
            .font(.system(size: 28, weight: .light, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 56, height: 56)
            .liquidGlass(Circle(), tint: color.opacity(0.25))
    }
}

struct PodRing: View {
    let progress: Double
    var body: some View {
        let color = progress < 0.05 ? Palette.low : progress < 0.15 ? Palette.high : Palette.accent
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct WarningCard: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(Palette.low)
            .card(padding: 14)
    }
}

// MARK: - Quick log sheets

struct BolusSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var units = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var value: Double? { Double(units.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        EntrySheet(title: "Bolus", height: 240, canSave: (value ?? 0) > 0, saving: saving, onSave: save) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    TextField("0", text: $units)
                        .font(Theme.numeral(34))
                        .keyboardType(.decimalPad)
                        .focused($focused)
                    Text("units").font(.system(.title3, design: .rounded)).foregroundStyle(.secondary)
                }
                .modifier(FieldBackground(height: 72))
                if let error { Text(error).font(.footnote).foregroundStyle(Palette.low) }
            }
        }
        .onAppear { focused = true }
    }

    private func save() {
        guard let value else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.logInsulin(units: value, at: .now, note: nil)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct PodSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date.now
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        EntrySheet(title: "New Pod", height: 240, canSave: true, saving: saving, onSave: save) {
            VStack(spacing: 12) {
                DatePicker("Changed", selection: $date, in: Date.now.addingTimeInterval(-3 * 86400)...Date.now)
                    .font(.system(.body, design: .rounded))
                    .modifier(FieldBackground(height: 64))
                if let error { Text(error).font(.footnote).foregroundStyle(Palette.low) }
            }
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.logPodChange(at: date)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Chart

struct GlucoseChart: View {
    let readings: [ServerStatus.Reading]
    let insulin: [ServerStatus.InsulinEntry]
    let settings: AlertSettings?
    let hours: Int

    var body: some View {
        let low = settings?.low ?? 70
        let high = settings?.high ?? 250
        let unit = settings?.unit ?? "mgdl"
        let start = Date.now.addingTimeInterval(-Double(hours) * 3600)
        let doses = insulin.filter { $0.time >= start.timeIntervalSince1970 }
        let top = max(300, (readings.map(\.mgdl).max() ?? 0) + 20)

        Chart {
            RectangleMark(
                xStart: .value("Start", start),
                xEnd: .value("End", Date.now),
                yStart: .value("Low", low),
                yEnd: .value("High", high)
            )
            .foregroundStyle(Palette.inRange.opacity(0.10))

            ForEach(readings) { r in
                AreaMark(x: .value("Time", r.date), yStart: .value("Base", 40), yEnd: .value("Glucose", r.mgdl))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(colors: [Palette.accent.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                    )
                LineMark(x: .value("Time", r.date), y: .value("Glucose", r.mgdl))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Palette.accent.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                PointMark(x: .value("Time", r.date), y: .value("Glucose", r.mgdl))
                    .symbolSize(hours <= 6 ? 22 : 8)
                    .foregroundStyle(Glucose.color(r.mgdl, low: low, high: high))
            }

            ForEach(doses) { d in
                PointMark(x: .value("Time", Date(timeIntervalSince1970: d.time)), y: .value("Dose", top - 10))
                    .symbol { Image(systemName: "drop.fill").font(.system(size: 9)).foregroundStyle(Palette.accent) }
                    .annotation(position: .bottom, spacing: 2) {
                        Text(String(format: "%.1f", d.units)).font(.system(size: 9, design: .rounded)).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: start...Date.now)
        .chartYScale(domain: 40...top)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [low, high]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(Glucose.format(v, unit: unit)).font(.caption2) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .stride(by: .hour, count: hours <= 3 ? 1 : hours <= 6 ? 2 : hours <= 12 ? 3 : 6)) { _ in
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .overlay {
            if readings.isEmpty {
                Text("No readings yet").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
