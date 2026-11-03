import SwiftUI

/// Formatting and colours shared by the app and the Live Activity.
enum Glucose {
    static let mmolFactor = 18.0182
    static let urgentLow: Double = 55

    static func isMmol(_ unit: String) -> Bool { unit == "mmol" }

    static func format(_ mgdl: Double, unit: String) -> String {
        isMmol(unit) ? String(format: "%.1f", mgdl / mmolFactor) : String(Int(mgdl.rounded()))
    }

    static func formatDelta(_ delta: Double?, unit: String) -> String {
        guard let delta else { return "" }
        let value = isMmol(unit) ? delta / mmolFactor : delta
        let magnitude = isMmol(unit) ? String(format: "%.1f", abs(value)) : String(Int(abs(value).rounded()))
        if magnitude == "0" || magnitude == "0.0" { return "±0" }
        return (value > 0 ? "+" : "−") + magnitude
    }

    static func unitLabel(_ unit: String) -> String { isMmol(unit) ? "mmol/L" : "mg/dL" }

    static func arrow(_ trend: String) -> String {
        switch trend {
        case "doubleUp": return "⇈"
        case "singleUp": return "↑"
        case "fortyFiveUp": return "↗"
        case "flat": return "→"
        case "fortyFiveDown": return "↘"
        case "singleDown": return "↓"
        case "doubleDown": return "⇊"
        case "notComputable", "rateOutOfRange": return "?"
        default: return ""
        }
    }

    /// Spoken by VoiceOver.
    static func trendDescription(_ trend: String) -> String {
        switch trend {
        case "doubleUp": return "rising quickly"
        case "singleUp": return "rising"
        case "fortyFiveUp": return "rising slowly"
        case "flat": return "steady"
        case "fortyFiveDown": return "falling slowly"
        case "singleDown": return "falling"
        case "doubleDown": return "falling quickly"
        default: return "trend unknown"
        }
    }

    static func color(_ mgdl: Double, low: Double, high: Double) -> Color {
        if mgdl <= low { return Palette.low }
        if mgdl >= high { return Palette.high }
        return Palette.inRange
    }

    /// "Pod 41h" / "Pod 50m" / "Pod expired".
    static func podText(expiry: Date?, now: Date = .now) -> String? {
        guard let expiry else { return nil }
        let minutes = Int(expiry.timeIntervalSince(now) / 60)
        if minutes <= 0 { return "Pod expired" }
        if minutes < 120 { return "Pod \(minutes)m" }
        return "Pod \(minutes / 60)h"
    }

    static func iobText(_ iob: Double?) -> String? {
        guard let iob, iob > 0 else { return nil }
        return String(format: "IOB %.1fu", iob)
    }
}

/// Soft, calm range colours, readable in light and dark mode.
enum Palette {
    /// Sage green.
    static let inRange = Color(red: 0.42, green: 0.72, blue: 0.62)
    /// Rose coral: noticeable without being harsh.
    static let low = Color(red: 0.91, green: 0.38, blue: 0.45)
    /// Warm amber.
    static let high = Color(red: 0.93, green: 0.66, blue: 0.30)
    static let stale = Color(white: 0.6)
    /// Muted plum accent for controls.
    static let accent = Color(red: 0.55, green: 0.42, blue: 0.68)
}

/// Tiny line graph of recent readings with the target range shaded.
struct Sparkline: View {
    let values: [Double]
    let low: Double
    let high: Double
    var lineWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let lo = min(values.min() ?? low, low) - 10
            let hi = max(values.max() ?? high, high) + 10
            let y = { (v: Double) -> CGFloat in geo.size.height * CGFloat(1 - (v - lo) / (hi - lo)) }
            let step = values.count > 1 ? geo.size.width / CGFloat(values.count - 1) : 0

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Palette.inRange.opacity(0.18))
                    .frame(height: max(0, y(low) - y(high)))
                    .offset(y: y(high))
                Path { path in
                    for (i, v) in values.enumerated() {
                        let p = CGPoint(x: CGFloat(i) * step, y: y(v))
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                }
                .stroke(Color.primary.opacity(0.8), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                if let last = values.last {
                    Circle()
                        .fill(Glucose.color(last, low: low, high: high))
                        .frame(width: lineWidth * 3, height: lineWidth * 3)
                        .position(x: CGFloat(values.count - 1) * step, y: y(last))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
