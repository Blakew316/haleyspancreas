import ActivityKit
import Foundation

/// The Live Activity's data. The server builds `ContentState` as JSON in
/// server/src/payloads.ts, so field names and types must stay in sync with it.
/// Times are Unix seconds (Double), not `Date`, because ActivityKit decodes `Date`
/// relative to 2001 and the server sends Unix time.
struct GlucoseActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var mgdl: Double
        var trend: String
        var readingTime: Double
        var delta: Double?
        var unit: String
        var low: Double
        var high: Double
        var iob: Double?
        var podExpiresAt: Double?
        /// Last hour of readings, oldest first.
        var history: [Double]

        var readingDate: Date { Date(timeIntervalSince1970: readingTime) }
        var podExpiryDate: Date? { podExpiresAt.map { Date(timeIntervalSince1970: $0) } }
    }

    /// Whose glucose this is, e.g. "Haley".
    var name: String
}
