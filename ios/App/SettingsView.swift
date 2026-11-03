import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var activities: LiveActivityManager
    @State private var draft: AlertSettings?
    @State private var testSent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Settings")
                .padding(.horizontal, 20)
            Form {
                Section {
                    Toggle("Alerts", isOn: $model.alertsEnabled)
                    Toggle("Live Activity", isOn: Binding(
                        get: { activities.isRunning },
                        set: { on in
                            Task {
                                if on { await activities.start(from: model.status) } else { await activities.stop() }
                            }
                        }
                    ))
                    if model.notificationsAllowed == false {
                        Button("Allow Notifications") { Task { await model.requestNotificationPermission() } }
                    }
                    Button {
                        Task {
                            try? await model.sendTestAlert()
                            testSent = true
                            try? await Task.sleep(for: .seconds(2))
                            testSent = false
                        }
                    } label: {
                        HStack {
                            Text("Send Test Alert")
                            Spacer()
                            if testSent {
                                Image(systemName: "checkmark").foregroundStyle(Palette.inRange)
                            }
                        }
                    }
                }

                if let binding = Binding($draft) {
                    Section("Range") {
                        Picker("Units", selection: binding.unit) {
                            Text("mg/dL").tag("mgdl")
                            Text("mmol/L").tag("mmol")
                        }
                        .pickerStyle(.menu)
                        threshold("Urgent low", value: binding.urgentLow,
                                  range: span(40, min(80, binding.wrappedValue.low - 5)), unit: binding.wrappedValue.unit)
                        threshold("Low", value: binding.low,
                                  range: span(max(50, binding.wrappedValue.urgentLow + 5), min(150, binding.wrappedValue.high - 5)),
                                  unit: binding.wrappedValue.unit)
                        threshold("High", value: binding.high,
                                  range: span(max(120, binding.wrappedValue.low + 5), 400), unit: binding.wrappedValue.unit)
                    }
                }

                Section("Server") {
                    LabeledContent("Address", value: model.config?.baseURL.host() ?? "—")
                    if let last = model.status?.server.lastSuccessAt {
                        LabeledContent("Updated") {
                            Text(Date(timeIntervalSince1970: last), style: .relative)
                        }
                    }
                    if let e = model.status?.server.lastError {
                        Text(e).font(.footnote).foregroundStyle(Palette.low)
                    }
                    Button("Disconnect", role: .destructive) { model.config = nil }
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .onAppear { draft = draft ?? model.status?.settings }
            .onChange(of: model.status?.settings) { _, new in
                if draft == nil { draft = new }
            }
            // Saves a moment after the last change; no Save button needed.
            .task(id: draft) {
                guard let draft, let current = model.status?.settings, draft != current else { return }
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                try? await model.saveSettings(draft)
            }
            .sensoryFeedback(.success, trigger: testSent)
        }
        .background(AmbientBackground(color: Palette.accent))
    }

    /// A valid range even if the bounds arrive crossed (a crossed range would crash).
    private func span(_ a: Double, _ b: Double) -> ClosedRange<Double> { min(a, b)...max(a, b) }

    private func threshold(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        Stepper(value: value, in: range, step: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Glucose.format(value.wrappedValue, unit: unit)) \(Glucose.unitLabel(unit))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
