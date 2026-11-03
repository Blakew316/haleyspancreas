import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.config == nil {
            SetupView()
        } else {
            TabView {
                Tab("Today", systemImage: "drop") { DashboardView() }
                Tab("Log", systemImage: "square.and.pencil") { LogView() }
                Tab("Settings", systemImage: "gearshape") { SettingsView() }
            }
            .minimizingTabBar()
        }
    }
}

/// First launch: connect to the server.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var url = "https://"
    @State private var secret = ""
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        ZStack {
            AmbientBackground(color: Palette.inRange)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "drop.halffull")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Palette.low)
                        Text("Haley's Pancreas")
                            .font(Theme.title(38))
                        Text("Her Dexcom readings on your Lock Screen, Dynamic Island and Apple Watch, with gentle alerts when it matters.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 48)

                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow(text: "Server address")
                        TextField("https://haleys-pancreas.fly.dev", text: $url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                        Divider()
                        Eyebrow(text: "App secret")
                        SecureField("From the server's APP_SECRET", text: $secret)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .card()

                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(Palette.low)
                    }

                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            if connecting { ProgressView() }
                            Text(connecting ? "Connecting…" : "Connect")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(connecting || secret.isEmpty || URL(string: url)?.host == nil)
                }
                .padding(24)
            }
        }
    }

    private func connect() async {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)) else { return }
        connecting = true
        defer { connecting = false }
        do {
            try await model.connect(url: parsed, secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
            await model.requestNotificationPermission()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
