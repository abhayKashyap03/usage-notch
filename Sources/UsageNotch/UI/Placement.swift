import SwiftUI

/// Where the pill sits and, as a consequence, which way it grows and which corners
/// are rounded. Top attaches beside the notch; the sides hug the screen edge.
struct Placement: Equatable {
    var edge: NotchEdge
    var anchor: NotchAnchor

    static var current: Placement {
        Placement(edge: Settings.shared.edge, anchor: Settings.shared.anchor)
    }

    /// SwiftUI alignment for the content inside the (larger) window.
    var alignment: Alignment {
        switch edge {
        case .top:
            switch anchor {
            case .rightOfNotch: return .topLeading
            case .leftOfNotch: return .topTrailing
            case .center: return .top
            }
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// Content rect inside the window, top-left origin — the same geometry AppKit
    /// needs for hit testing.
    func contentRect(window: CGSize, content: CGSize) -> CGRect {
        var origin = CGPoint.zero
        switch edge {
        case .top:
            switch anchor {
            case .rightOfNotch: origin.x = 0
            case .leftOfNotch: origin.x = window.width - content.width
            case .center: origin.x = (window.width - content.width) / 2
            }
        case .left:
            origin.y = (window.height - content.height) / 2
        case .right:
            origin.x = window.width - content.width
            origin.y = (window.height - content.height) / 2
        }
        return CGRect(origin: origin, size: content)
    }

    /// Corner radii, rounded only on the sides facing away from the screen edge.
    func radii(_ r: CGFloat) -> Corners {
        switch edge {
        case .top: return Corners(topLeft: 0, topRight: 0, bottomRight: r, bottomLeft: r)
        case .left: return Corners(topLeft: 0, topRight: r, bottomRight: r, bottomLeft: 0)
        case .right: return Corners(topLeft: r, topRight: 0, bottomRight: 0, bottomLeft: r)
        }
    }
}

struct Corners: Equatable {
    var topLeft: CGFloat = 0
    var topRight: CGFloat = 0
    var bottomRight: CGFloat = 0
    var bottomLeft: CGFloat = 0
}
