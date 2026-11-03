import ActivityKit
import SwiftUI
import WidgetKit

@main
struct GlucoseWidgetsBundle: WidgetBundle {
    var body: some Widget {
        GlucoseLiveActivity()
    }
}

/// Lock Screen banner, Dynamic Island (portrait and landscape on iOS 27), StandBy,
/// and, through `.small`, the Apple Watch Smart Stack and CarPlay.
struct GlucoseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlucoseActivityAttributes.self) { context in
            LockScreenView(state: context.state, name: context.attributes.name, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            let color = context.isStale ? Palette.stale : Glucose.color(s.mgdl, low: s.low, high: s.high)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Glucose.format(s.mgdl, unit: s.unit))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(color)
                            .strikethrough(context.isStale)
                        Text(Glucose.arrow(s.trend))
                            .font(.title)
                            .foregroundStyle(color)
                    }
                    .padding(.leading, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityText(s, stale: context.isStale))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Glucose.formatDelta(s.delta, unit: s.unit)) \(Glucose.unitLabel(s.unit))")
                            .font(.headline)
                        ReadingAge(date: s.readingDate)
                            .font(.caption)
                            .foregroundStyle(context.isStale ? .red : .secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        Sparkline(values: s.history, low: s.low, high: s.high)
                            .frame(height: 36)
                        DetailsRow(state: s)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                // Fixed width in landscape on iOS 27, so keep this to the number alone.
                Text(Glucose.format(s.mgdl, unit: s.unit))
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(color)
                    .strikethrough(context.isStale)
                    .minimumScaleFactor(0.7)
            } compactTrailing: {
                Text(Glucose.arrow(s.trend))
                    .foregroundStyle(color)
            } minimal: {
                Text(Glucose.format(s.mgdl, unit: s.unit))
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.6)
            }
            .keylineTint(color)
        }
        .supplementalActivityFamilies([.small])
    }
}

private func accessibilityText(_ s: GlucoseActivityAttributes.ContentState, stale: Bool) -> String {
    let value = "\(Glucose.format(s.mgdl, unit: s.unit)) \(Glucose.unitLabel(s.unit)), \(Glucose.trendDescription(s.trend))"
    return stale ? "\(value). Data is out of date." : value
}

/// Time since the reading, counting up live without needing an update.
struct ReadingAge: View {
    let date: Date
    var body: some View {
        Text(date, style: .relative) + Text(" ago")
    }
}

struct DetailsRow: View {
    let state: GlucoseActivityAttributes.ContentState
    var body: some View {
        HStack {
            if let iob = Glucose.iobText(state.iob) {
                Label(iob, systemImage: "drop.fill")
            }
            Spacer(minLength: 8)
            if let pod = Glucose.podText(expiry: state.podExpiryDate) {
                Label(pod, systemImage: "clock")
            }
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }
}

struct LockScreenView: View {
    let state: GlucoseActivityAttributes.ContentState
    let name: String
    let isStale: Bool
    @Environment(\.activityFamily) private var family

    var body: some View {
        let s = state
        let color = isStale ? Palette.stale : Glucose.color(s.mgdl, low: s.low, high: s.high)
        switch family {
        case .small:
            // Apple Watch Smart Stack and CarPlay.
            HStack(spacing: 6) {
                Text(Glucose.format(s.mgdl, unit: s.unit))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(color)
                    .strikethrough(isStale)
                Text(Glucose.arrow(s.trend)).font(.title3).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Glucose.formatDelta(s.delta, unit: s.unit)).font(.caption.weight(.semibold))
                    ReadingAge(date: s.readingDate).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText(s, stale: isStale))
        default:
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Glucose.format(s.mgdl, unit: s.unit))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(color)
                            .strikethrough(isStale)
                        Text(Glucose.arrow(s.trend)).font(.title).foregroundStyle(color)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityText(s, stale: isStale))
                    HStack(spacing: 6) {
                        Text("\(Glucose.formatDelta(s.delta, unit: s.unit)) \(Glucose.unitLabel(s.unit))")
                        Text("·")
                        if isStale {
                            Text("No recent data").foregroundStyle(.red)
                        } else {
                            ReadingAge(date: s.readingDate)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                VStack(alignment: .trailing, spacing: 6) {
                    Sparkline(values: s.history, low: s.low, high: s.high)
                        .frame(height: 44)
                    DetailsRow(state: s)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .foregroundStyle(.white)
        }
    }
}

#Preview("Lock Screen", as: .content, using: GlucoseActivityAttributes(name: "Haley")) {
    GlucoseLiveActivity()
} contentStates: {
    GlucoseActivityAttributes.ContentState(
        mgdl: 112, trend: "fortyFiveDown", readingTime: Date.now.addingTimeInterval(-90).timeIntervalSince1970,
        delta: -4, unit: "mgdl", low: 70, high: 250, iob: 1.4,
        podExpiresAt: Date.now.addingTimeInterval(30 * 3600).timeIntervalSince1970,
        history: [140, 136, 131, 128, 125, 122, 120, 118, 117, 116, 114, 112]
    )
    GlucoseActivityAttributes.ContentState(
        mgdl: 58, trend: "singleDown", readingTime: Date.now.timeIntervalSince1970,
        delta: -6, unit: "mgdl", low: 70, high: 250, iob: nil, podExpiresAt: nil,
        history: [95, 90, 84, 78, 72, 66, 62, 58]
    )
}
