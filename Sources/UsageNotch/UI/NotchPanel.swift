import AppKit
import SwiftUI

/// Borderless panel that floats above the menu bar on every space.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        // Above the menu bar, but still below system alerts.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// A non-activating panel that refuses key status never receives clicks at all,
    /// so accept it: taking key here does not activate the app or disturb the
    /// frontmost window's focus ring.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
