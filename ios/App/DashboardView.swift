import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var activities: LiveActivityManager
    @State private var hours = 3

    private var status: ServerStatus? { model.status }

    var body: some View {
        let accent = rangeColor
        NavigationStack {
            ZStack {
                AmbientBackground(color: accent)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacing) {
                        header
                        hero(color: accent)
                        if let warning = serverWarning { WarningCard(message: warning) }
                        chartCard
                        HStack(spacing: Theme.spacing) {
                            insulinCard
                            podCard
                        }
                        liveActivityCard
                        if !(status?.activeAlerts.isEmpty ?? true) { snoozeCard }
                        Text("For awareness only. Use the Dexcom and Omnipod 5 apps for treatment decisions, and keep their alarms on.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
                .refreshable { await model.refresh() }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: Header and hero

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.greeting.uppercased())
                .font(Theme.eyebrow)
                .tracking(1.6)
                .foregroundStyle(.secondary)
            Text("Haley")
                .font(Theme.title(40))
        }
        .padding(.top, 12)
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
                HStack(alignment: .center, spacing: 18) {
                    Text(Glucose.format(latest.mgdl, unit: settings.unit))
                        .font(Theme.numeral(112))
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
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Glucose.format(latest.mgdl, unit: settings.unit)) \(Glucose.unitLabel(settings.unit)), \(Glucose.trendDescription(latest.trend))")
            .animation(.smooth, value: latest.mgdl)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("—").font(Theme.numeral(112)).foregroundStyle(.tertiary)
                Text(model.lastError ?? "Waiting for the first reading…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
    }

    private func ageText(_ date: Date) -> String {
        let minutes = Int(Date.now.timeIntervalSince(date) / 60)
        return minutes < 1 ? "Just now" : "\(minutes) min ago"
    }

    private var serverWarning: String? {
        if let e = status?.server.lastError { return "The server can't reach Dexcom Share: \(e)" }
        if let e = model.lastError, status != nil { return "Can't reach the server: \(e)" }
        return nil
    }

    // MARK: Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow(text: "Last \(hours) hours")
                Spacer()
                Picker("Range", selection: $hours) {
                    Text("3h").tag(3)
                    Text("6h").tag(6)
                    Text("12h").tag(12)
                    Text("24h").tag(24)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            GlucoseChart(
                readings: (status?.readings ?? []).filter { Date.now.timeIntervalSince($0.date) <= Double(hours) * 3600 },
                insulin: status?.insulin ?? [],
                settings: status?.settings,
                hours: hours
            )
            .frame(height: 210)
        }
        .card()
    }

    // MARK: Small cards

    private var insulinCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Insulin on board")
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.1f", status?.iob ?? 0))
                    .font(Theme.numeral(36))
                Text("u").font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
            }
            Text("From logged doses")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .card()
    }

    private var podCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Pod")
            if let pod = status?.pod {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let total = pod.expiresAt - pod.changedAt
                    let left = max(0, pod.expiresAt - context.date.timeIntervalSince1970)
                    HStack(spacing: 12) {
                        PodRing(progress: total > 0 ? left / total : 0)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(left > 0 ? "\(Int(left / 3600))h" : "Expired")
                                .font(Theme.numeral(28))
                            Text(left > 0 ? "remaining" : "change soon")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Text("Not logged").font(Theme.numeral(24)).foregroundStyle(.secondary)
                Text("Log a pod change").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .card()
    }

    private var liveActivityCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "platter.filled.top.iphone")
                .font(.title2.weight(.light))
                .foregroundStyle(Palette.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Activity").font(.system(.headline, design: .rounded))
                Text(activities.lastError ?? "Lock Screen, Dynamic Island and Apple Watch")
                    .font(.caption)
                    .foregroundStyle(activities.lastError == nil ? Color.secondary : Palette.low)
            }
            Spacer()
            Toggle("Live Activity", isOn: Binding(
                get: { activities.isRunning },
                set: { on in
                    Task {
                        if on { await activities.start(from: status) } else { await activities.stop() }
                    }
                }
            ))
            .labelsHidden()
        }
        .card()
        .sensoryFeedback(.selection, trigger: activities.isRunning)
    }

    private var snoozeCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Alerts").font(.system(.headline, design: .rounded))
                if let until = status?.snoozeUntil {
                    Text("Snoozed until \(Date(timeIntervalSince1970: until).formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Urgent lows are never snoozed").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button("30 minutes") { snooze(30) }
                Button("1 hour") { snooze(60) }
                Button("2 hours") { snooze(120) }
                if status?.snoozeUntil != nil { Button("Resume alerts", role: .destructive) { snooze(0) } }
            } label: {
                Label("Snooze", systemImage: "moon.zzz")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
            }
            .buttonStyle(.bordered)
        }
        .card()
    }

    private func snooze(_ minutes: Int) {
        Task { try? await model.snooze(minutes: minutes) }
    }
}

// MARK: - Components

struct TrendBadge: View {
    let trend: String
    let color: Color
    var body: some View {
        Text(Glucose.arrow(trend))
            .font(.system(size: 34, weight: .light, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 64, height: 64)
            .background(Circle().fill(color.opacity(0.14)))
            .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 1))
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
            AxisMarks(values: .stride(by: .hour, count: hours <= 6 ? 1 : hours <= 12 ? 3 : 6)) { _ in
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
