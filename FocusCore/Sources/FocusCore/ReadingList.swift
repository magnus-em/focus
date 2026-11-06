import Foundation

/// Focus's own read-later library (replaces Readwise Reader, whose trial ended 11/6).
/// Metadata lives in one JSON file; each article's cleaned HTML in its own file.
public struct ReadingItem: Codable, Identifiable, Equatable, Sendable {
    public enum Location: String, Codable, CaseIterable, Sendable {
        case inbox, later, archive
        public var title: String {
            switch self {
            case .inbox: "Inbox"
            case .later: "Later"
            case .archive: "Archive"
            }
        }
    }

    public var id: UUID
    public var url: String
    public var title: String
    public var author: String?
    public var siteName: String?
    public var summary: String?
    public var imageURL: String?
    public var savedAt: Date
    public var publishedAt: Date?
    public var location: Location
    public var tags: [String]
    public var progress: Double
    public var openedAt: Date?
    public var wordCount: Int?
    public var hasContent: Bool
    /// The running category when it was saved, and whether that was focus time.
    public var label: String?
    public var wasFocus: Bool?
    /// "blocked", "extension", "readwise", "csv", "app".
    public var source: String
    public var readwiseID: String?
    public var highlights: [ReadingHighlight]
    public var contentError: String?

    public init(id: UUID = UUID(), url: String, title: String, author: String? = nil, siteName: String? = nil,
                summary: String? = nil, imageURL: String? = nil, savedAt: Date = Date(), publishedAt: Date? = nil,
                location: Location = .inbox, tags: [String] = [], progress: Double = 0, openedAt: Date? = nil,
                wordCount: Int? = nil, hasContent: Bool = false, label: String? = nil, wasFocus: Bool? = nil,
                source: String, readwiseID: String? = nil, highlights: [ReadingHighlight] = [], contentError: String? = nil) {
        self.id = id; self.url = url; self.title = title; self.author = author; self.siteName = siteName
        self.summary = summary; self.imageURL = imageURL; self.savedAt = savedAt; self.publishedAt = publishedAt
        self.location = location; self.tags = tags; self.progress = progress; self.openedAt = openedAt
        self.wordCount = wordCount; self.hasContent = hasContent; self.label = label; self.wasFocus = wasFocus
        self.source = source; self.readwiseID = readwiseID; self.highlights = highlights; self.contentError = contentError
    }

    public var host: String {
        let h = URL(string: url)?.host ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Minutes at 250 words a minute.
    public var readingMinutes: Int? { wordCount.map { max(1, Int((Double($0) / 250).rounded())) } }
}

public struct ReadingHighlight: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var note: String?
    public var createdAt: Date
    public init(id: UUID = UUID(), text: String, note: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.text = text; self.note = note; self.createdAt = createdAt
    }
}

public enum ReadingURL {
    /// Same article whatever tracking junk or fragment the link carried.
    public static func key(_ url: String) -> String {
        guard var c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return url.lowercased() }
        c.fragment = nil
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        if c.host?.hasPrefix("www.") == true { c.host = String(c.host!.dropFirst(4)) }
        if c.scheme == "http" { c.scheme = "https" }
        let junk: (String) -> Bool = { n in
            let n = n.lowercased()
            return n.hasPrefix("utm_") || ["fbclid", "gclid", "ref", "ref_src", "smid", "mc_cid", "mc_eid", "igshid", "si"].contains(n)
        }
        let kept = (c.queryItems ?? []).filter { !junk($0.name) }
        c.queryItems = kept.isEmpty ? nil : kept
        if c.path.count > 1, c.path.hasSuffix("/") { c.path.removeLast() }
        if c.path == "/" { c.path = "" }
        return c.string ?? url
    }
}

// MARK: - Readwise import

/// One document from Readwise Reader's `GET /api/v3/list/` (withHtmlContent=true).
public struct ReadwiseDocument: Sendable {
    public var id: String
    public var item: ReadingItem?
    public var html: String?
    /// A highlight: text, its note and the document it belongs to.
    public var highlight: (parent: String, value: ReadingHighlight)?
}

public enum ReadwiseImport {
    public struct Page: Sendable {
        public var documents: [ReadwiseDocument]
        public var nextCursor: String?
    }

    public static func parseListPage(_ data: Data) throws -> Page {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Readwise", code: 1, userInfo: [NSLocalizedDescriptionKey: "Readwise sent something unreadable"])
        }
        let results = obj["results"] as? [[String: Any]] ?? []
        return Page(documents: results.compactMap(document), nextCursor: obj["nextPageCursor"] as? String)
    }

    static func document(_ d: [String: Any]) -> ReadwiseDocument? {
        guard let id = (d["id"] as? String) ?? (d["id"] as? Int).map(String.init) else { return nil }
        let category = d["category"] as? String ?? "article"
        let created = date(d["created_at"]) ?? Date()
        if category == "highlight" || category == "note" {
            guard let parent = d["parent_id"] as? String,
                  let text = (d["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let note = (d["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ReadwiseDocument(id: id, item: nil, html: nil,
                                    highlight: (parent, ReadingHighlight(text: text, note: note, createdAt: created)))
        }
        guard let loc = d["location"] as? String, loc != "feed" else { return nil }
        let url = (d["source_url"] as? String).flatMap { $0.hasPrefix("http") ? $0 : nil } ?? (d["url"] as? String ?? "")
        guard !url.isEmpty else { return nil }
        let tagDict = d["tags"] as? [String: Any] ?? [:]
        let cleanTags = tagDict.map { key, value in ((value as? [String: Any])?["name"] as? String) ?? key }.sorted()
        let html = (d["html_content"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let item = ReadingItem(
            url: url,
            title: (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url,
            author: nonEmpty(d["author"]),
            siteName: nonEmpty(d["site_name"]),
            summary: nonEmpty(d["summary"]),
            imageURL: nonEmpty(d["image_url"]),
            savedAt: date(d["saved_at"]) ?? created,
            publishedAt: date(d["published_date"]),
            location: location(loc),
            tags: cleanTags,
            progress: min(1, max(0, (d["reading_progress"] as? Double) ?? 0)),
            openedAt: date(d["last_opened_at"]) ?? date(d["first_opened_at"]),
            wordCount: d["word_count"] as? Int,
            hasContent: html != nil,
            source: "readwise",
            readwiseID: id)
        return ReadwiseDocument(id: id, item: item, html: html, highlight: nil)
    }

    public static func location(_ s: String) -> ReadingItem.Location {
        switch s.lowercased() {
        case "archive", "archived": .archive
        case "later", "shortlist": .later
        default: .inbox
        }
    }

    static func nonEmpty(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func date(_ v: Any?) -> Date? {
        if let n = v as? Double { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        if let n = v as? Int { return Date(timeIntervalSince1970: Double(n) > 1e11 ? Double(n) / 1000 : Double(n)) }
        guard let s = v as? String, !s.isEmpty else { return nil }
        return parseDate(s)
    }

    static func parseDate(_ s: String) -> Date? {
        let s = s.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd HH:mm:ssZZZZZ", "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "MMMM d, yyyy h:mm a", "MMMM d, yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // MARK: CSV exports

    /// Reader's library export (Preferences → Export → CSV) and Readwise's highlights
    /// export (readwise.io/export → CSV). Columns are matched by name, so either works.
    public struct CSVResult: Sendable {
        public var items: [ReadingItem] = []
        /// Highlights keyed by the document title they belong to (the highlights export has no URL).
        public var highlightsByTitle: [String: [ReadingHighlight]] = [:]
        public var highlightsByURL: [String: [ReadingHighlight]] = [:]
    }

    public static func parseCSV(_ text: String) -> CSVResult {
        let rows = csvRows(text)
        guard let header = rows.first?.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) else { return CSVResult() }
        func col(_ names: String...) -> Int? {
            for n in names { if let i = header.firstIndex(of: n) { return i } }
            for n in names { if let i = header.firstIndex(where: { $0.contains(n) }) { return i } }
            return nil
        }
        var out = CSVResult()
        let highlightCol = header.firstIndex(of: "highlight")
        if let hc = highlightCol {
            let titleCol = col("book title", "title")
            let urlCol = col("url", "source url")
            let noteCol = col("note")
            let atCol = col("highlighted at", "created")
            for r in rows.dropFirst() {
                func v(_ i: Int?) -> String { guard let i, i < r.count else { return "" }; return r[i].trimmingCharacters(in: .whitespacesAndNewlines) }
                let text = v(hc)
                guard !text.isEmpty else { continue }
                let h = ReadingHighlight(text: text, note: v(noteCol).isEmpty ? nil : v(noteCol),
                                         createdAt: parseDate(v(atCol)) ?? Date())
                if !v(urlCol).isEmpty, v(urlCol).hasPrefix("http") {
                    out.highlightsByURL[ReadingURL.key(v(urlCol)), default: []].append(h)
                } else if !v(titleCol).isEmpty {
                    out.highlightsByTitle[v(titleCol), default: []].append(h)
                }
            }
            return out
        }
        guard let urlCol = col("url", "source url", "link") else { return out }
        let titleCol = col("title")
        let authorCol = col("author")
        let savedCol = col("saved date", "saved at", "saved", "created")
        let progressCol = col("reading progress", "progress")
        let locationCol = col("location")
        let tagsCol = col("document tags", "tags")
        let idCol = col("id")
        let summaryCol = col("summary")
        for r in rows.dropFirst() {
            func v(_ i: Int?) -> String { guard let i, i < r.count else { return "" }; return r[i].trimmingCharacters(in: .whitespacesAndNewlines) }
            let url = v(urlCol)
            guard url.hasPrefix("http") else { continue }
            let loc = v(locationCol).lowercased()
            if loc == "feed" { continue }
            var progress = Double(v(progressCol).replacingOccurrences(of: "%", with: "")) ?? 0
            if progress > 1 { progress /= 100 }
            out.items.append(ReadingItem(
                url: url,
                title: v(titleCol).isEmpty ? url : v(titleCol),
                author: v(authorCol).isEmpty ? nil : v(authorCol),
                summary: v(summaryCol).isEmpty ? nil : v(summaryCol),
                savedAt: parseDate(v(savedCol)) ?? Date(),
                location: location(loc),
                tags: tagList(v(tagsCol)),
                progress: min(1, max(0, progress)),
                source: "csv",
                readwiseID: v(idCol).isEmpty ? nil : v(idCol)))
        }
        return out
    }

    /// "['a', 'b']", "a, b" or "a;b".
    static func tagList(_ s: String) -> [String] {
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
            .filter { !$0.isEmpty }
    }

    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r": row.append(field); field = ""; rows.append(row); row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}
