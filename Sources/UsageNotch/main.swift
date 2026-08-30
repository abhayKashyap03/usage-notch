import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Top-level code is nonisolated; the delegate callback is already on the main thread.
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            let controller = NotchController()
            controller.install()
            self.controller = controller
        }
    }
}

// `UsageNotch --dump` prints what the providers see and exits. Handy for checking
// the parsers without staring at the pill.
// `UsageNotch --account` runs the opt-in Anthropic usage check and reports what came
// back, which is otherwise invisible behind a background queue.
if CommandLine.arguments.contains("--account") {
    let provider = AnthropicAccountProvider()
    let result = provider.probeBlocking()
    if let result {
        print("5h: \(result.session?.percent.map(String.init) ?? "–")%   " +
              "7d: \(result.week?.percent.map(String.init) ?? "–")%   plan: \(result.plan ?? "unknown")")
    } else {
        print("no usable answer: \(provider.lastFailure ?? "unknown")")
    }
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    let now = Date()
    for usage in [ClaudeCodeProvider().fetch(now: now), CodexProvider().fetch(now: now)] {
        let five = usage.session.percent.map { "\($0)%" } ?? "–"
        let week = usage.week.percent.map { "\($0)%" } ?? "–"
        let reset = Fmt.countdown(to: usage.session.resetsAt) ?? "n/a"
        print("\(usage.name): \(five) of \(usage.session.label) (resets in \(reset)), \(week) of \(usage.week.label)")
        print("  tokens=\(Fmt.tokens(usage.tokens)) cost=\(usage.costUSD.map(Fmt.money) ?? "n/a") plan=\(usage.plan ?? "n/a") estimated=\(usage.session.estimated)")
        print("  note=\(usage.footnote ?? "-")")
    }
    let liveSessions = AgentActivityProvider().sessions()
    for session in liveSessions {
        let age = Int(Date().timeIntervalSince(session.lastActivity))
        print("\(session.kind.rawValue) session: \(session.project) — \(session.detail) " +
              "(\(session.isWorking ? "working" : "idle"), up \(Fmt.elapsed(session.elapsed)), last event \(age)s ago)")
    }
    for workspace in DeveloperContextProvider().workspaces(for: liveSessions, now: now) {
        let divergence = [workspace.ahead > 0 ? "ahead \(workspace.ahead)" : nil,
                          workspace.behind > 0 ? "behind \(workspace.behind)" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        print("workspace: \(workspace.project) [\(workspace.branch)] — " +
              "\(workspace.isClean ? "clean" : "\(workspace.changedFiles) changed")" +
              (divergence.isEmpty ? "" : " (\(divergence))"))
    }
    exit(0)
}

// `UsageNotch --placement` prints where the pill would land on every screen and
// anchor, using the same geometry the app runs on.
if CommandLine.arguments.contains("--placement") {
    for screen in NSScreen.screens {
        let geo = NotchGeometry.current(preferring: screen.localizedName)
        let window = CGSize(width: 400, height: 280)
        print("\(screen.localizedName)  notch=\(geo.hasNotch)  topInset=\(geo.topInset)  anchorRect=\(geo.anchorRect)")
        for edge in NotchEdge.allCases {
            for anchor in (edge == .top ? NotchAnchor.allCases : [.center]) {
                let placement = Placement(edge: edge, anchor: anchor, notch: geo.islandSize)
                print("   \(edge.rawValue)/\(anchor.rawValue): \(geo.frame(for: window, placement: placement))")
            }
        }
    }
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render") {
    let dir = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "./build/shots"
    NSApplication.shared.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { RenderHarness.run(outputDirectory: dir) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
