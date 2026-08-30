import AppKit

/// Lets several notch widgets share one screen edge without sitting on top of each
/// other. Each app publishes the rect it occupies; the others read those claims and
/// step aside. Priority is the bundle id in alphabetical order, so two apps never
/// chase each other back and forth.
enum NotchClaims {
    private struct Claim: Codable {
        var app: String
        var screen: String
        var edge: String
        var x: Double, y: Double, w: Double, h: Double
        var updated: Double

        var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }

    /// A claim from an app that has quit stops counting shortly after.
    private static let staleAfter: TimeInterval = 45
    private static let gap: CGFloat = 8

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchWidgets", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("claims.json")
    }

    private static var me: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    private static func load() -> [String: Claim] {
        guard let data = try? Data(contentsOf: url),
              let claims = try? JSONDecoder().decode([String: Claim].self, from: data)
        else { return [:] }
        return claims
    }

    private static func save(_ claims: [String: Claim]) {
        guard let data = try? JSONEncoder().encode(claims) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func publish(rect: CGRect, screen: String, edge: NotchEdge, now: Date = Date()) {
        var claims = load()
        claims[me] = Claim(app: me, screen: screen, edge: edge.rawValue,
                           x: rect.minX, y: rect.minY, w: rect.width, h: rect.height,
                           updated: now.timeIntervalSince1970)
        save(claims.filter { now.timeIntervalSince1970 - $0.value.updated < staleAfter || $0.key == me })
    }

    static func withdraw() {
        var claims = load()
        claims.removeValue(forKey: me)
        save(claims)
    }

    /// Rects claimed by *other* widgets that this app should yield to.
    static func obstacles(screen: String, now: Date = Date()) -> [CGRect] {
        load().values
            .filter { $0.app != me && $0.screen == screen }
            .filter { now.timeIntervalSince1970 - $0.updated < staleAfter }
            // An island is pinned to the hardware notch and cannot move, so everyone
            // yields to it. Otherwise the alphabetically earlier bundle id keeps its
            // spot, which makes the outcome stable instead of a shoving match.
            .filter { $0.edge == NotchEdge.island.rawValue || $0.app < me }
            .map(\.rect)
    }

    /// Slides `rect` along its edge until it stops overlapping anything claimed.
    static func resolve(rect: CGRect, edge: NotchEdge, screen: NSScreen, obstacles: [CGRect]) -> CGRect {
        // Island mode is pinned around the notch; it has nowhere to go.
        guard edge != .island, !obstacles.isEmpty else { return rect }
        var moved = rect
        for _ in 0..<6 {
            guard let hit = obstacles.first(where: { $0.intersects(moved) }) else { break }
            if edge.isSide {
                moved.origin.y = hit.minY - moved.height - gap
                if moved.minY < screen.frame.minY { moved.origin.y = hit.maxY + gap }
            } else {
                moved.origin.x = hit.maxX + gap
                if moved.maxX > screen.frame.maxX { moved.origin.x = hit.minX - moved.width - gap }
            }
        }
        return moved
    }
}
