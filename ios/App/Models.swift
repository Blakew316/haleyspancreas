import Foundation

/// Mirrors GET /status in server/src/api.ts. Times are Unix seconds.
struct ServerStatus: Decodable {
    struct Reading: Decodable, Identifiable, Hashable {
        var mgdl: Double
        var trend: String
        var time: Double
        var id: Double { time }
        var date: Date { Date(timeIntervalSince1970: time) }
    }

    struct Pod: Decodable {
        var id: String
        var changedAt: Double
        var expiresAt: Double
        var graceEndsAt: Double
        var expiryDate: Date { Date(timeIntervalSince1970: expiresAt) }
        var changedDate: Date { Date(timeIntervalSince1970: changedAt) }
    }

    struct InsulinEntry: Decodable, Identifiable {
        var id: String
        var units: Double
        var time: Double
        var note: String?
    }

    struct CarbEntry: Decodable, Identifiable {
        var id: String
        var grams: Double
        var time: Double
        var note: String?
    }

    struct PodChange: Decodable, Identifiable {
        var id: String
        var time: Double
    }

    struct ServerHealth: Decodable {
        var lastPollAt: Double?
        var lastSuccessAt: Double?
        var lastError: String?
    }

    var now: Double
    var readings: [Reading]
    var delta: Double?
    var ratePerMinute: Double?
    var iob: Double
    var pod: Pod?
    var insulin: [InsulinEntry]
    var carbs: [CarbEntry]
    var podChanges: [PodChange]
    var settings: AlertSettings
    var snoozeUntil: Double?
    var activeAlerts: [String]
    var server: ServerHealth

    var latest: Reading? { readings.first }
}

struct AlertSettings: Codable, Equatable {
    struct Repeat: Codable, Equatable {
        var urgentLow: Double
        var urgentLowSoon: Double
        var low: Double
        var high: Double
        var noData: Double
    }

    var urgentLow: Double
    var low: Double
    var high: Double
    var urgentLowSoonMinutes: Double
    var fastRate: Double
    var noDataMinutes: Double
    var repeatMinutes: Repeat
    var unit: String
}

extension ServerStatus {
    /// What the Live Activity shows, built the same way as the server's `contentState`.
    func contentState() -> GlucoseActivityAttributes.ContentState? {
        guard let latest else { return nil }
        let hourAgo = latest.time - 3600
        return GlucoseActivityAttributes.ContentState(
            mgdl: latest.mgdl,
            trend: latest.trend,
            readingTime: latest.time,
            delta: delta,
            unit: settings.unit,
            low: settings.low,
            high: settings.high,
            iob: iob > 0 ? iob : nil,
            podExpiresAt: pod?.expiresAt,
            history: Array(readings.filter { $0.time > hourAgo }.map(\.mgdl).reversed())
        )
    }
}
