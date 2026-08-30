import Foundation
import SwiftUI

/// A single rate-limit window reported (or estimated) for a provider.
struct UsageWindow {
    /// 0...1 fraction of the window consumed. `nil` when the provider cannot say.
    var fraction: Double?
    /// When the window rolls over, if known.
    var resetsAt: Date?
    /// Short human label, e.g. "5h" or "week".
    var label: String
    /// True when the fraction is inferred locally rather than reported by the vendor.
    var estimated: Bool

    var percent: Int? { fraction.map { Int(($0 * 100).rounded()) } }
}

enum ProviderStatus {
    case ok
    case idle       // configured, but no recent activity found
    case missing    // provider not installed on this machine
    case failed(String)

    var isUsable: Bool {
        switch self {
        case .ok, .idle: return true
        case .missing, .failed: return false
        }
    }
}

struct ProviderUsage: Identifiable {
    var id: String
    var name: String
    var glyph: String            // short badge text, e.g. "CC"
    var tint: Color
    var session: UsageWindow     // rolling short window (5h for both vendors)
    var week: UsageWindow
    var tokens: Int
    var costUSD: Double?
    var plan: String?
    var lastActivity: Date?
    var status: ProviderStatus
    var footnote: String?

    /// Value the pill shows when collapsed.
    var headlineFraction: Double? {
        session.fraction ?? week.fraction
    }
}

struct UsageSnapshot {
    var providers: [ProviderUsage] = []
    var updatedAt: Date = .distantPast

    var visible: [ProviderUsage] { providers.filter { $0.status.isUsable } }

    /// Worst-case window across providers — drives the pill's warning colour.
    var peakFraction: Double? {
        visible.compactMap(\.headlineFraction).max()
    }
}

enum UsageTone {
    case calm, warn, critical

    static func forFraction(_ f: Double?) -> UsageTone {
        guard let f else { return .calm }
        if f >= 0.85 { return .critical }
        if f >= 0.6 { return .warn }
        return .calm
    }

    var color: Color {
        switch self {
        case .calm: return Color(red: 0.36, green: 0.85, blue: 0.60)
        case .warn: return Color(red: 0.98, green: 0.75, blue: 0.32)
        case .critical: return Color(red: 0.98, green: 0.42, blue: 0.42)
        }
    }
}

enum Fmt {
    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(n) / 1_000_000)
        default: return String(format: "%.2fB", Double(n) / 1_000_000_000)
        }
    }

    static func money(_ v: Double) -> String {
        v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }

    /// "2h 14m" style countdown; nil when the date is absent or already past.
    static func countdown(to date: Date?, from now: Date = Date()) -> String? {
        guard let date else { return nil }
        let secs = Int(date.timeIntervalSince(now))
        guard secs > 0 else { return nil }
        let h = secs / 3600, m = (secs % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
