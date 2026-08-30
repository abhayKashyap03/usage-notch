import Foundation
import AppKit

/// Which screen edge the pill is attached to.
enum NotchEdge: String, CaseIterable {
    case top, island, left, right

    var title: String {
        switch self {
        case .top: return "Top (beside notch)"
        case .island: return "Dynamic island (around notch)"
        case .left: return "Left edge"
        case .right: return "Right edge"
        }
    }

    var isSide: Bool { self == .left || self == .right }
    var isIsland: Bool { self == .island }
}

/// Where the pill hangs relative to the notch (or the menu bar on notch-less Macs).
enum NotchAnchor: String, CaseIterable {
    case rightOfNotch, leftOfNotch, center

    func title(hasNotch: Bool) -> String {
        switch self {
        case .rightOfNotch: return hasNotch ? "Right of notch" : "Right of center"
        case .leftOfNotch: return hasNotch ? "Left of notch" : "Left of center"
        case .center: return hasNotch ? "Centered under notch" : "Centered"
        }
    }
}

/// What the Claude ring measures, since Claude Code does not publish a limit locally.
enum ClaudeMetric: String, CaseIterable {
    case cost, tokens

    var title: String { self == .cost ? "Estimated spend" : "Total tokens" }
}

/// Small UserDefaults wrapper. Deliberately plain: the app has no preferences window,
/// everything is driven from the status-bar menu.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum K {
        static let anchor = "anchor"
        static let hidden = "miniMode"
        static let showClaude = "showClaude"
        static let showCodex = "showCodex"
        static let claudeMetric = "claudeMetric"
        static let claudeSessionLimit = "claudeSessionLimit"   // 0 == auto
        static let claudeWeeklyLimit = "claudeWeeklyLimit"     // 0 == auto
        static let useAnthropicAccount = "useAnthropicAccount"
        static let refreshSeconds = "refreshSeconds"
        static let preferredScreen = "preferredScreen"
        static let edge = "edge"
        static let sideOffset = "sideOffset"
        static let topOffset = "topOffset"
        static let showAgents = "showAgents"
    }

    private init() {
        d.register(defaults: [
            K.anchor: NotchAnchor.rightOfNotch.rawValue,
            K.hidden: false,
            K.showClaude: true,
            K.showCodex: true,
            K.claudeMetric: ClaudeMetric.cost.rawValue,
            K.claudeSessionLimit: 0.0,
            K.claudeWeeklyLimit: 0.0,
            K.useAnthropicAccount: false,
            K.refreshSeconds: 45.0,
            K.preferredScreen: "",
            K.edge: NotchEdge.top.rawValue,
            K.sideOffset: 0.0,
            K.topOffset: 0.0,
            K.showAgents: true,
        ])
    }

    var edge: NotchEdge {
        get { NotchEdge(rawValue: d.string(forKey: K.edge) ?? "") ?? .top }
        set { d.set(newValue.rawValue, forKey: K.edge) }
    }

    /// Drag offsets, in points, applied after the base placement: horizontal when
    /// attached to the top, vertical when attached to a side.
    var sideOffset: Double {
        get { d.double(forKey: K.sideOffset) }
        set { d.set(newValue, forKey: K.sideOffset) }
    }

    var topOffset: Double {
        get { d.double(forKey: K.topOffset) }
        set { d.set(newValue, forKey: K.topOffset) }
    }

    func resetOffsets() {
        topOffset = 0
        sideOffset = 0
    }

    var anchor: NotchAnchor {
        get { NotchAnchor(rawValue: d.string(forKey: K.anchor) ?? "") ?? .rightOfNotch }
        set { d.set(newValue.rawValue, forKey: K.anchor) }
    }

    /// "Work mode": the pill shrinks to a nub that only peeks open on hover.
    var miniMode: Bool {
        get { d.bool(forKey: K.hidden) }
        set { d.set(newValue, forKey: K.hidden) }
    }

    /// Show live Claude Code / Codex sessions, Dynamic-Island style.
    var showAgents: Bool {
        get { d.bool(forKey: K.showAgents) }
        set { d.set(newValue, forKey: K.showAgents) }
    }

    var showClaude: Bool {
        get { d.bool(forKey: K.showClaude) }
        set { d.set(newValue, forKey: K.showClaude) }
    }

    var showCodex: Bool {
        get { d.bool(forKey: K.showCodex) }
        set { d.set(newValue, forKey: K.showCodex) }
    }

    var claudeMetric: ClaudeMetric {
        get { ClaudeMetric(rawValue: d.string(forKey: K.claudeMetric) ?? "") ?? .cost }
        set { d.set(newValue.rawValue, forKey: K.claudeMetric) }
    }

    /// Ceiling for one 5-hour Claude block. 0 means "auto": use the busiest block on record.
    var claudeSessionLimit: Double {
        get { d.double(forKey: K.claudeSessionLimit) }
        set { d.set(newValue, forKey: K.claudeSessionLimit) }
    }

    var claudeWeeklyLimit: Double {
        get { d.double(forKey: K.claudeWeeklyLimit) }
        set { d.set(newValue, forKey: K.claudeWeeklyLimit) }
    }

    /// Opt-in: read the Claude Code OAuth token from the login keychain and ask
    /// Anthropic for the real plan utilisation instead of estimating locally.
    var useAnthropicAccount: Bool {
        get { d.bool(forKey: K.useAnthropicAccount) }
        set { d.set(newValue, forKey: K.useAnthropicAccount) }
    }

    /// `NSScreen.localizedName` of the display to live on. Empty means automatic:
    /// the notched built-in screen if there is one, otherwise the main display.
    var preferredScreen: String? {
        get {
            let name = d.string(forKey: K.preferredScreen) ?? ""
            return name.isEmpty ? nil : name
        }
        set { d.set(newValue ?? "", forKey: K.preferredScreen) }
    }

    var refreshSeconds: Double {
        get { max(15, d.double(forKey: K.refreshSeconds)) }
        set { d.set(newValue, forKey: K.refreshSeconds) }
    }
}
