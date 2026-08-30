import SwiftUI

/// Every size decision in one place, so the AppKit hit region and the SwiftUI frame
/// can never disagree about how big the pill currently is.
struct Layout: Equatable {
    var placement: Placement
    var providers: Int
    var sessions: Int

    private var providerRows: CGFloat { CGFloat(max(providers, 1)) * 66 }
    private var sessionRows: CGFloat { sessions == 0 ? 0 : CGFloat(sessions) * 26 + 8 }

    /// Body of the open panel, excluding any notch band above it.
    private var panelBody: CGFloat { 44 + providerRows + sessionRows + 26 }

    func size(for mode: NotchMode) -> CGSize {
        switch placement.edge {
        case .island: return islandSize(mode)
        case .left, .right: return sideSize(mode)
        case .top: return topSize(mode)
        }
    }

    private func topSize(_ mode: NotchMode) -> CGSize {
        switch mode {
        case .mini: return CGSize(width: 52, height: 9)
        case .pill: return CGSize(width: sessions > 0 ? 214 : 158, height: 30)
        case .expanded: return CGSize(width: 326, height: panelBody)
        }
    }

    private func sideSize(_ mode: NotchMode) -> CGSize {
        switch mode {
        case .mini: return CGSize(width: 9, height: 46)
        case .pill:
            let rows = CGFloat(max(providers, 1)) * 26 + CGFloat(sessions) * 20
            return CGSize(width: 38, height: 22 + rows)
        case .expanded: return CGSize(width: 326, height: panelBody)
        }
    }

    /// Island mode wraps the hardware notch: the shape is flush with the top of the
    /// screen and wide enough that the cutout disappears inside it, with readouts
    /// sitting either side of the gap.
    private func islandSize(_ mode: NotchMode) -> CGSize {
        let notch = placement.notch
        switch mode {
        case .mini:
            return CGSize(width: notch.width + 28, height: notch.height)
        case .pill:
            let wing: CGFloat = sessions > 0 ? 116 : 78
            return CGSize(width: notch.width + wing * 2, height: notch.height)
        case .expanded:
            return CGSize(width: max(notch.width + 90, 360), height: notch.height + panelBody)
        }
    }

    /// Horizontal gap the content must leave in the middle for the cutout.
    var notchGap: CGFloat { placement.edge.isIsland ? placement.notch.width : 0 }
}
