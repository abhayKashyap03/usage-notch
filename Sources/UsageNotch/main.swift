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
    for session in AgentActivityProvider().sessions() {
        let age = Int(Date().timeIntervalSince(session.lastActivity))
        print("\(session.kind.rawValue) session: \(session.project) — \(session.detail) " +
              "(\(session.isWorking ? "working" : "idle"), up \(Fmt.elapsed(session.elapsed)), last event \(age)s ago)")
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
