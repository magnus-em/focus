import Foundation

/// Screen rows and block notes older than `ScreenWatcher`'s 30 live days,
/// one JSON line each in `Focus/archive/screen-YYYY-MM.jsonl` and
/// `screen-notes-YYYY-MM.jsonl`, kept so Insights can look back months.
enum ScreenArchive {
    struct NoteLine: Codable {
        var key: Date
        var notes: ScreenWatcher.ActivityNotes
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/archive", isDirectory: true)
    }

    private static func month(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func append(spans: [ScreenSpan], notes: [Date: ScreenWatcher.ActivityNotes]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            var lines: [String: Data] = [:]
            for s in spans {
                lines["screen-\(month(s.start)).jsonl", default: Data()].append(try enc.encode(s) + Data("\n".utf8))
            }
            for (k, n) in notes {
                lines["screen-notes-\(month(k)).jsonl", default: Data()]
                    .append(try enc.encode(NoteLine(key: k, notes: n)) + Data("\n".utf8))
            }
            for (name, data) in lines {
                let url = directory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try data.write(to: url, options: .atomic)
                    continue
                }
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: data)
            }
            return true
        } catch {
            return false
        }
    }

    /// Archived rows overlapping the range (the live 30 days aren't here).
    static func spans(from: Date, to: Date) -> [ScreenSpan] {
        var out: [ScreenSpan] = []
        var m = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: from)) ?? from
        let dec = JSONDecoder()
        while m < to {
            let url = directory.appendingPathComponent("screen-\(month(m)).jsonl")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    if let s = try? dec.decode(ScreenSpan.self, from: Data(line.utf8)), s.end > from, s.start < to { out.append(s) }
                }
            }
            m = Calendar.current.date(byAdding: .month, value: 1, to: m) ?? to
        }
        return out.sorted { $0.start < $1.start }
    }
}
