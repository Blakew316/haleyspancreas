import ActivityKit
import Foundation

/// Starts the glucose Live Activity and hands every push token to the server.
///
/// Three kinds of token:
/// - the activity's own token, which the server uses to update it every 5 minutes;
/// - the push-to-start token, which lets the server start a fresh activity by itself.
///   iOS ends a Live Activity after 8 hours, so the server replaces it before then
///   without anyone opening the app;
/// - the regular push token for alerts, handled in AppDelegate.
@MainActor
final class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var observed = Set<String>()
    private var tokens: [String: String] = [:]
    private var startedTask: Task<Void, Never>?
    private var startTokenTask: Task<Void, Never>?
    private let startedAtKey = "activityStartedAt"

    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Call once at launch, including background launches, so push-started activities get registered.
    func startObserving() {
        guard startedTask == nil else { return }
        for activity in Activity<GlucoseActivityAttributes>.activities {
            observe(activity)
        }
        startedTask = Task {
            for await activity in Activity<GlucoseActivityAttributes>.activityUpdates {
                observe(activity)
            }
        }
        startTokenTask = Task {
            for await data in Activity<GlucoseActivityAttributes>.pushToStartTokenUpdates {
                AppModel.shared.pushToStartTokenUpdated(data.hexString)
            }
        }
        refreshRunning()
    }

    private func refreshRunning() {
        isRunning = Activity<GlucoseActivityAttributes>.activities.contains { $0.activityState == .active }
    }

    private func startedAt(for activity: Activity<GlucoseActivityAttributes>) -> Date {
        var map = UserDefaults.standard.dictionary(forKey: startedAtKey) as? [String: Double] ?? [:]
        if let t = map[activity.id] { return Date(timeIntervalSince1970: t) }
        let now = Date.now
        map[activity.id] = now.timeIntervalSince1970
        // Forget activities that no longer exist.
        let live = Set(Activity<GlucoseActivityAttributes>.activities.map(\.id))
        map = map.filter { live.contains($0.key) || $0.key == activity.id }
        UserDefaults.standard.set(map, forKey: startedAtKey)
        return now
    }

    private func observe(_ activity: Activity<GlucoseActivityAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        let started = startedAt(for: activity)
        refreshRunning()

        Task {
            for await data in activity.pushTokenUpdates {
                let token = data.hexString
                tokens[activity.id] = token
                await AppModel.shared.activityTokenUpdated(token, startedAt: started)
            }
        }
        Task {
            for await state in activity.activityStateUpdates {
                refreshRunning()
                if state == .ended || state == .dismissed {
                    // Ended by iOS or swiped away. Ask the server to start a new one; only the
                    // switch in the app turns it off for good.
                    await AppModel.shared.activityEnded(token: tokens[activity.id], userTurnedOff: false)
                    tokens[activity.id] = nil
                    observed.remove(activity.id)
                }
            }
        }
    }

    func start(from status: ServerStatus?) async {
        lastError = nil
        guard enabled else {
            lastError = "Live Activities are turned off for this app in Settings."
            return
        }
        guard let state = status?.contentState() else {
            lastError = "No glucose reading yet. Try again once the server has data."
            return
        }
        // One at a time.
        for activity in Activity<GlucoseActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        do {
            let activity = try Activity.request(
                attributes: GlucoseActivityAttributes(name: "Haley"),
                content: ActivityContent(state: state, staleDate: state.readingDate.addingTimeInterval(11 * 60), relevanceScore: 100),
                pushType: .token
            )
            observe(activity)
            await AppModel.shared.registerDevice(wantsLiveActivity: true)
        } catch {
            lastError = error.localizedDescription
        }
        refreshRunning()
    }

    func stop() async {
        for activity in Activity<GlucoseActivityAttributes>.activities {
            let token = tokens[activity.id]
            tokens[activity.id] = nil
            observed.remove(activity.id)
            await activity.end(nil, dismissalPolicy: .immediate)
            await AppModel.shared.activityEnded(token: token, userTurnedOff: true)
        }
        await AppModel.shared.activityEnded(token: nil, userTurnedOff: true)
        refreshRunning()
    }

    /// While the app is open, show new readings immediately without waiting for the push.
    func updateLocally(from status: ServerStatus?) {
        guard let state = status?.contentState() else { return }
        for activity in Activity<GlucoseActivityAttributes>.activities where activity.content.state.readingTime < state.readingTime {
            Task {
                await activity.update(ActivityContent(state: state, staleDate: state.readingDate.addingTimeInterval(11 * 60), relevanceScore: 100))
            }
        }
    }
}
