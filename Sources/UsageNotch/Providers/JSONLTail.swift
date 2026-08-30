import Foundation

/// Incremental line reader for append-only JSONL logs.
///
/// Session transcripts grow all day and are re-read on every refresh tick, so we
/// remember where we stopped and only decode the bytes that arrived since. Files
/// that shrink (rotation, truncation) are re-read from the top.
final class JSONLTail {
    private typealias Cursor = ClaudeCache.Cursor

    private var cursors: [String: Cursor] = [:]

    /// Cursors survive a restart through `ClaudeCache`.
    var savedCursors: [String: ClaudeCache.Cursor] {
        get { cursors }
        set { cursors = newValue }
    }

    /// Hands `body` the raw bytes of every complete line appended since the previous
    /// call. Raw `Data` rather than `String`: converting hundreds of megabytes of
    /// transcript to `String` just to discard most of it is the whole cost.
    /// A trailing partial line is left for the next pass.
    func newLines(at path: String, body: (Data) -> Void) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        var cursor = cursors[path] ?? Cursor(offset: 0, size: 0)
        if size < cursor.offset { cursor = Cursor(offset: 0, size: 0) }  // truncated / replaced
        guard size > cursor.offset else {
            cursor.size = size
            cursors[path] = cursor
            return
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: cursor.offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return }
            // Only consume through the final newline so half-written records are retried.
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
            let complete = data[data.startIndex...lastNewline]
            cursor.offset += UInt64(complete.count)
            cursor.size = size
            cursors[path] = cursor

            var start = complete.startIndex
            while let nl = complete[start...].firstIndex(of: UInt8(ascii: "\n")) {
                if nl > start { body(Data(complete[start..<nl])) }
                start = complete.index(after: nl)
            }
        } catch {
            return
        }
    }

    func forget(pathsNotIn keep: Set<String>) {
        for key in cursors.keys where !keep.contains(key) { cursors.removeValue(forKey: key) }
    }
}

enum FS {
    /// Recursively collects files with `ext`, skipping anything older than `newerThan`.
    static func files(under root: String, ext: String, newerThan: Date? = nil) -> [(path: String, modified: Date)] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: URL(fileURLWithPath: root),
                                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [(String, Date)] = []
        for case let url as URL in e {
            guard url.pathExtension == ext else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let mod = values?.contentModificationDate ?? .distantPast
            if let newerThan, mod < newerThan { continue }
            out.append((url.path, mod))
        }
        return out
    }
}
