import Foundation

/// On-disk memo of everything already parsed out of the Claude transcripts.
///
/// The transcript folder runs to hundreds of megabytes, and re-reading it on every
/// launch costs seconds. The cache stores the extracted per-turn usage plus the byte
/// offset reached in each file, so a restart only reads what was appended since.
struct ClaudeCache: Codable {
    struct Entry: Codable {
        var t: Double        // timestamp
        var m: String        // model
        var i: Int           // input
        var o: Int           // output
        var w: Int           // cache write
        var r: Int           // cache read
        var c: Double        // cost
    }

    struct Cursor: Codable {
        var offset: UInt64
        var size: UInt64
    }

    var version = 2
    var cursors: [String: Cursor] = [:]
    var entries: [Entry] = []
    var seen: [String] = []

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("claude-cache.json")
    }

    static func load() -> ClaudeCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(ClaudeCache.self, from: data),
              cache.version == ClaudeCache().version
        else { return nil }
        return cache
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}
