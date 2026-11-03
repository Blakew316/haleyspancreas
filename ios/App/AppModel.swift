import ActivityKit
import Foundation
import UIKit
import UserNotifications

/// App-wide state: server connection, latest status, and this phone's push tokens.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var status: ServerStatus?
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefresh: Date?
    @Published var config: ServerConfig? {
        didSet { saveConfig() }
    }
    @Published var deviceName: String {
        didSet { defaults.set(deviceName, forKey: Keys.deviceName); Task { await registerDevice() } }
    }
    @Published var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: Keys.alertsEnabled); Task { await registerDevice() } }
    }
    @Published private(set) var notificationsAllowed: Bool?
    @Published private(set) var criticalAlertsAllowed = false

    private let defaults = UserDefaults.standard
    private var refreshTask: Task<Void, Never>?

    private enum Keys {
        static let serverURL = "serverURL"
        static let secret = "appSecret"
        static let deviceId = "deviceId"
        static let deviceName = "deviceName"
        static let alertsEnabled = "alertsEnabled"
        static let alertToken = "alertToken"
        static let pushToStartToken = "pushToStartToken"
    }

    /// Debug builds from Xcode use Apple's sandbox push servers; TestFlight/App Store builds use production.
    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    let deviceId: String

    private init() {
        if let id = defaults.string(forKey: Keys.deviceId) {
            deviceId = id
        } else {
            deviceId = UUID().uuidString
            defaults.set(deviceId, forKey: Keys.deviceId)
        }
        deviceName = defaults.string(forKey: Keys.deviceName) ?? "iPhone"
        alertsEnabled = defaults.object(forKey: Keys.alertsEnabled) as? Bool ?? true
        if let url = defaults.url(forKey: Keys.serverURL), let secret = Keychain.get(Keys.secret) {
            config = ServerConfig(baseURL: url, secret: secret)
        }
    }

    var client: ServerClient? { config.map(ServerClient.init) }

    private func saveConfig() {
        guard let config else {
            defaults.removeObject(forKey: Keys.serverURL)
            Keychain.delete(Keys.secret)
            status = nil
            return
        }
        defaults.set(config.baseURL, forKey: Keys.serverURL)
        Keychain.set(config.secret, for: Keys.secret)
    }

    // MARK: Setup

    /// Checks the connection, then saves it and registers this phone.
    func connect(url: URL, secret: String) async throws {
        let candidate = ServerConfig(baseURL: url, secret: secret)
        let fetched = try await ServerClient(config: candidate).status()
        config = candidate
        status = fetched
        await registerDevice()
    }

    func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        // .criticalAlert is only granted if Apple approved the entitlement; otherwise it is ignored.
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert])
        await refreshNotificationSettings()
        UIApplication.shared.registerForRemoteNotifications()
    }

    func refreshNotificationSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized
        criticalAlertsAllowed = settings.criticalAlertSetting == .enabled
    }

    // MARK: Tokens (called by AppDelegate and LiveActivityManager)

    func alertTokenUpdated(_ token: String) {
        defaults.set(token, forKey: Keys.alertToken)
        Task { await registerDevice() }
    }

    func pushToStartTokenUpdated(_ token: String) {
        defaults.set(token, forKey: Keys.pushToStartToken)
        Task { await registerDevice() }
    }

    func activityTokenUpdated(_ token: String, startedAt: Date) async {
        guard let client else { return }
        do {
            try await client.send("PUT", "devices/\(deviceId)/activity", [
                "token": AnyEncodable(token),
                "startedAt": AnyEncodable(startedAt.timeIntervalSince1970),
            ])
        } catch {
            // The device may not be registered yet; register and retry once.
            await registerDevice()
            try? await client.send("PUT", "devices/\(deviceId)/activity", [
                "token": AnyEncodable(token),
                "startedAt": AnyEncodable(startedAt.timeIntervalSince1970),
            ])
        }
    }

    func activityEnded(token: String?, userTurnedOff: Bool) async {
        guard let client else { return }
        var body: [String: AnyEncodable] = ["keepRunning": AnyEncodable(!userTurnedOff)]
        if let token { body["token"] = AnyEncodable(token) }
        try? await client.send("DELETE", "devices/\(deviceId)/activity", body)
    }

    func registerDevice(wantsLiveActivity: Bool? = nil) async {
        guard let client else { return }
        var body: [String: AnyEncodable] = [
            "name": AnyEncodable(deviceName),
            "environment": AnyEncodable(Self.apnsEnvironment),
            "alertsEnabled": AnyEncodable(alertsEnabled),
        ]
        if let t = defaults.string(forKey: Keys.alertToken) { body["alertToken"] = AnyEncodable(t) }
        if let t = defaults.string(forKey: Keys.pushToStartToken) { body["pushToStartToken"] = AnyEncodable(t) }
        if let wantsLiveActivity { body["wantsLiveActivity"] = AnyEncodable(wantsLiveActivity) }
        do {
            try await client.send("PUT", "devices/\(deviceId)", body)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Status

    /// Refreshes every 15 seconds while the app is open. Background updates come by push.
    func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard let client else { return }
        do {
            status = try await client.status()
            lastError = nil
            lastRefresh = .now
            LiveActivityManager.shared.updateLocally(from: status)
        } catch is CancellationError {
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Actions

    func logInsulin(units: Double, at date: Date, note: String?) async throws {
        var body: [String: AnyEncodable] = ["units": AnyEncodable(units), "time": AnyEncodable(date.timeIntervalSince1970)]
        if let note, !note.isEmpty { body["note"] = AnyEncodable(note) }
        try await client?.send("POST", "log/insulin", body)
        await refresh()
    }

    func logCarbs(grams: Double, at date: Date, note: String?) async throws {
        var body: [String: AnyEncodable] = ["grams": AnyEncodable(grams), "time": AnyEncodable(date.timeIntervalSince1970)]
        if let note, !note.isEmpty { body["note"] = AnyEncodable(note) }
        try await client?.send("POST", "log/carbs", body)
        await refresh()
    }

    func logPodChange(at date: Date) async throws {
        try await client?.send("POST", "log/pod", ["time": AnyEncodable(date.timeIntervalSince1970)])
        await refresh()
    }

    func deleteEntry(kind: String, id: String) async throws {
        try await client?.send("DELETE", "log/\(kind)/\(id)")
        await refresh()
    }

    func saveSettings(_ settings: AlertSettings) async throws {
        let _: AlertSettings? = try await client?.request("PUT", "settings", body: settings)
        await refresh()
    }

    func snooze(minutes: Int) async throws {
        try await client?.send("POST", "snooze", ["minutes": AnyEncodable(minutes)])
        await refresh()
    }

    func sendTestAlert() async throws {
        try await client?.send("POST", "test-alert", ["deviceId": AnyEncodable(deviceId)])
    }
}
