import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft: AlertSettings?
    @State private var message: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Notifications") {
                        statusText(model.notificationsAllowed == true ? "On" : "Off", ok: model.notificationsAllowed == true)
                    }
                    LabeledContent("Critical alerts") {
                        statusText(model.criticalAlertsAllowed ? "On" : "Not available", ok: model.criticalAlertsAllowed)
                    }
                    Toggle("Glucose alerts on this phone", isOn: $model.alertsEnabled)
                    TextField("This phone's name", text: $model.deviceName)
                    if model.notificationsAllowed != true {
                        Button("Allow notifications") { Task { await model.requestNotificationPermission() } }
                    }
                    Button("Send a test alert") {
                        Task {
                            do { try await model.sendTestAlert(); message = "Test alert sent." }
                            catch { message = error.localizedDescription }
                        }
                    }
                } header: {
                    Text("This iPhone")
                } footer: {
                    Text("Critical alerts sound even on silent and in Focus modes. Apple has to approve them for this app first. Until then, alerts are time-sensitive.")
                }

                if let binding = Binding($draft) {
                    Section {
                        Picker("Units", selection: binding.unit) {
                            Text("mg/dL").tag("mgdl")
                            Text("mmol/L").tag("mmol")
                        }
                        threshold("Urgent low", value: binding.urgentLow, range: 40...80, unit: binding.wrappedValue.unit)
                        threshold("Low", value: binding.low, range: 50...150, unit: binding.wrappedValue.unit)
                        threshold("High", value: binding.high, range: 120...400, unit: binding.wrappedValue.unit)
                        Stepper("Urgent low soon: \(Int(binding.wrappedValue.urgentLowSoonMinutes)) min ahead",
                                value: binding.urgentLowSoonMinutes, in: 0...60, step: 5)
                        Stepper("No data after \(Int(binding.wrappedValue.noDataMinutes)) min",
                                value: binding.noDataMinutes, in: 10...120, step: 5)
                        Stepper("Urgent low repeats every \(Int(binding.wrappedValue.repeatMinutes.urgentLow)) min",
                                value: binding.repeatMinutes.urgentLow, in: 1...30)
                    } header: {
                        Text("Alerts")
                    } footer: {
                        Text("Shared by every phone connected to this server. Urgent low alerts can't be snoozed.")
                    }

                    Section {
                        Button {
                            Task { await save() }
                        } label: {
                            HStack {
                                Text(saving ? "Saving…" : "Save alert settings")
                                Spacer()
                                if saving { ProgressView() }
                            }
                        }
                        .disabled(saving || draft == model.status?.settings)
                    }
                }

                if let message {
                    Section { Text(message).font(.footnote) }
                }

                Section("Server") {
                    LabeledContent("Address", value: model.config?.baseURL.host() ?? "—")
                    if let last = model.status?.server.lastSuccessAt {
                        LabeledContent("Last Dexcom check") {
                            Text(Date(timeIntervalSince1970: last), style: .relative) + Text(" ago")
                        }
                    }
                    if let e = model.status?.server.lastError {
                        Text(e).font(.footnote).foregroundStyle(Palette.low)
                    }
                    Button("Disconnect", role: .destructive) { model.config = nil }
                }

                Section {
                    Text("This app shows Dexcom Share data and your own logs. Readings arrive about every 5 minutes and can lag behind. It is not a medical device and doesn't replace the Dexcom or Omnipod 5 apps or their alarms.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AmbientBackground(color: Palette.accent))
            .navigationTitle("Settings")
            .onAppear { draft = draft ?? model.status?.settings }
            .onChange(of: model.status?.settings) { _, new in
                if draft == nil { draft = new }
            }
        }
    }

    private func statusText(_ text: String, ok: Bool) -> some View {
        Text(text).foregroundStyle(ok ? Palette.inRange : .secondary)
    }

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

    private func save() async {
        guard let draft else { return }
        saving = true
        defer { saving = false }
        do {
            try await model.saveSettings(draft)
            message = "Saved."
        } catch {
            message = error.localizedDescription
        }
    }
}
