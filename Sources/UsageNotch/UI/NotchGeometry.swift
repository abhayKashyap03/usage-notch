import AppKit

/// Resolves where the pill should live on the current display arrangement.
struct NotchGeometry {
    let screen: NSScreen
    /// The physical notch on Apple silicon laptops, or a synthetic centre strip.
    let anchorRect: CGRect
    /// Menu-bar height, i.e. how far down the usable desktop starts.
    let topInset: CGFloat
    let hasNotch: Bool

    /// What island mode should wrap. Real notch metrics when there is one, otherwise
    /// a virtual island of similar proportions so the mode still works.
    var islandSize: CGSize {
        hasNotch ? CGSize(width: anchorRect.width, height: anchorRect.height)
                 : CGSize(width: 180, height: max(topInset, 26))
    }

    static func current(preferring name: String? = Settings.shared.preferredScreen) -> NotchGeometry {
        // An explicit choice wins; otherwise prefer the notched built-in display,
        // then whichever screen currently owns the menu bar.
        let screen = name.flatMap { wanted in NSScreen.screens.first { $0.localizedName == wanted } }
            ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first!

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let notch = CGRect(x: left.maxX,
                               y: screen.frame.maxY - screen.safeAreaInsets.top,
                               width: max(right.minX - left.maxX, 120),
                               height: screen.safeAreaInsets.top)
            return NotchGeometry(screen: screen, anchorRect: notch,
                                 topInset: screen.safeAreaInsets.top, hasNotch: true)
        }

        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        let synthetic = CGRect(x: screen.frame.midX - 90,
                               y: screen.frame.maxY - menuBar,
                               width: 180, height: menuBar)
        return NotchGeometry(screen: screen, anchorRect: synthetic, topInset: menuBar, hasNotch: false)
    }

    /// Window frame for a given size and placement. The window is deliberately larger
    /// than the pill; `Placement.contentRect` says where the pill sits inside it.
    func frame(for size: CGSize, placement: Placement) -> CGRect {
        switch placement.edge {
        case .top:
            return topFrame(for: size, anchor: placement.anchor)
        case .island:
            let x = anchorRect.midX - size.width / 2
            return CGRect(x: x.rounded(), y: (screen.frame.maxY - size.height).rounded(),
                          width: size.width, height: size.height)
        case .left, .right:
            let x = placement.edge == .left
                ? screen.frame.minX
                : screen.frame.maxX - size.width
            let y = screen.visibleFrame.midY - size.height / 2
            return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        }
    }

    private func topFrame(for size: CGSize, anchor: NotchAnchor) -> CGRect {
        let gap: CGFloat = hasNotch ? 6 : 0
        // On a notched Mac the pill sits flush in the menu-bar strip; elsewhere it hangs below it.
        let top = hasNotch ? screen.frame.maxY : screen.frame.maxY - topInset

        var x: CGFloat
        switch anchor {
        case .rightOfNotch:
            x = anchorRect.maxX + gap
        case .leftOfNotch:
            x = anchorRect.minX - gap - size.width
        case .center:
            x = anchorRect.midX - size.width / 2
        }

        let minX = screen.frame.minX + 4
        let maxX = screen.frame.maxX - size.width - 4
        x = min(max(x, minX), maxX)

        let y = (anchor == .center && hasNotch)
            ? top - topInset - size.height    // clear of the notch itself
            : top - size.height
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Content grows away from the notch, so it hugs the pinned edge.
    static func contentAlignment(for anchor: NotchAnchor) -> NSLayoutConstraint.Attribute {
        anchor == .leftOfNotch ? .trailing : .leading
    }
}
