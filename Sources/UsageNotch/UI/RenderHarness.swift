import AppKit
import SwiftUI

/// `UsageNotch --render <dir>` snapshots each notch state to PNG. Screen Recording
/// permission is not always available, so this is how the UI gets eyeballed and how
/// the README screenshots are produced.
@MainActor
enum RenderHarness {
    static func run(outputDirectory: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

        let store = UsageStore()
        let state = NotchState()
        // No NSApplication run loop here, so fetch inline rather than waiting on
        // a main-queue hop that would never be delivered.
        store.refreshBlocking()

        let providers = max(store.snapshot.visible.count, 1)
        let edge = Settings.shared.edge
        for (mode, name) in [(NotchMode.mini, "mini"), (.pill, "pill"), (.expanded, "expanded")] {
            state.mode = mode
            state.placement = Placement(edge: edge, anchor: .rightOfNotch)
            let root = NotchRootView(store: store, state: state,
                                     onRefresh: {}, onToggleMini: {},
                                     onHitTargets: { _ in })
            let size = mode.size(edge: edge, providers: providers)
            snapshot(root, size: size, to: outputDirectory + "/\(name).png")
            print("rendered \(name).png  \(Int(size.width))x\(Int(size.height))")
        }
        exit(0)
    }

    /// Pumps the main run loop until `done()` or the deadline passes.
    private static func spin(until deadline: Date, done: () -> Bool) {
        while Date() < deadline && !done() {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            usleep(10_000)
        }
    }

    private static func snapshot<V: View>(_ view: V, size: CGSize, to path: String) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)

        // SwiftUI needs a window to run a layout pass; keep it offscreen.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        spin(until: Date().addingTimeInterval(0.4)) { false }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
}
