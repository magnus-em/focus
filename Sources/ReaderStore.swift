import Foundation
import FocusCore
import Security

struct ReaderPage {
    var url: String
    var title: String
    var author: String
    /// The page as the user's browser sees it (signed in past paywalls). Memory only until extracted.
    var html: String
    var source: String
}

/// Focus's read-later library, a small Readwise Reader of its own (the Readwise trial
/// ended 11/6). Pages come from the block page's "Save for later", the extension's
/// Save page / context menu, a pasted link, or an import of the Readwise library.
/// `Focus/reading/library.json` holds the list; `Focus/reading/articles/<id>.html`
/// the cleaned article, made by `ArticleExtractor`.
@MainActor
final class ReaderStore: ObservableObject {
    static let shared = ReaderStore()

    @Published private(set) var items: [ReadingItem] = []
    @Published private(set) var hasToken = ReaderKey.load() != nil
    @Published private(set) var importStatus: String? {
        didSet {
            guard let importStatus else { return }
            try? Data("\(ISO8601DateFormatter().string(from: Date())) \(importStatus)\n".utf8)
                .write(to: dir.appendingPathComponent("import-status.txt"), options: .atomic)
        }
    }
    @Published private(set) var importing = false
    @Published private(set) var fetching: Set<UUID> = []

    private let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Focus/reading", isDirectory: true)
    private var libraryURL: URL { dir.appendingPathComponent("library.json") }
    private var articlesDir: URL { dir.appendingPathComponent("articles", isDirectory: true) }
    private var fetchQueue: [UUID] = []
    private var fetchRunning = false
    private var persistWork: DispatchWorkItem?

    init() {
        if let data = try? Data(contentsOf: libraryURL),
           let decoded = try? JSONDecoder.iso.decode([ReadingItem].self, from: data) {
            items = decoded
        }
        migrateOldSaves()
    }

    var inboxCount: Int { items.filter { $0.location == .inbox }.count }

    func items(in location: ReadingItem.Location, matching query: String = "") -> [ReadingItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items
            .filter { $0.location == location }
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.host.contains(q)
                || ($0.author?.lowercased().contains(q) ?? false) || $0.tags.contains { $0.lowercased().contains(q) } }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func item(_ id: UUID) -> ReadingItem? { items.first { $0.id == id } }

    // MARK: Saving

    /// Returns "saved" or an error.
    func save(_ page: ReaderPage, label: String?, wasFocus: Bool?) async -> (status: String, error: String?) {
        guard let parsed = URL(string: page.url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
            return ("error", "Not a web page")
        }
        let key = ReadingURL.key(page.url)
        let id: UUID
        if let i = items.firstIndex(where: { ReadingURL.key($0.url) == key }) {
            if items[i].location == .archive { items[i].location = .inbox }
            items[i].savedAt = Date()
            id = items[i].id
        } else {
            let item = ReadingItem(url: page.url, title: page.title.isEmpty ? parsed.host ?? page.url : page.title,
                                   author: page.author.isEmpty ? nil : page.author, label: label, wasFocus: wasFocus,
                                   source: page.source)
            items.append(item)
            id = item.id
        }
        persist()
        if !page.html.isEmpty {
            await extract(id: id, html: page.html, baseURL: parsed)
        }
        if item(id)?.hasContent != true { enqueueFetch(id) }
        return ("saved", nil)
    }

    func addLink(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard URL(string: s)?.host != nil else { return }
        Task { _ = await save(ReaderPage(url: s, title: "", author: "", html: "", source: "app"), label: nil, wasFocus: nil) }
    }

    // MARK: Editing

    func move(_ id: UUID, to location: ReadingItem.Location) { update(id) { $0.location = location } }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: articleURL(id))
        persist()
    }

    func remove(url: String) {
        let key = ReadingURL.key(url)
        for item in items where ReadingURL.key(item.url) == key { delete(item.id) }
    }

    func setProgress(_ id: UUID, _ value: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }), abs(items[i].progress - value) > 0.005 else { return }
        items[i].progress = min(1, max(0, value))
        persist(soon: true)
    }

    func markOpened(_ id: UUID) { update(id) { $0.openedAt = Date() } }

    func addHighlight(_ id: UUID, text: String) -> ReadingHighlight? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let h = ReadingHighlight(text: t)
        update(id) { $0.highlights.append(h) }
        return h
    }

    func removeHighlight(_ id: UUID, highlight: UUID) { update(id) { $0.highlights.removeAll { $0.id == highlight } } }

    func setNote(_ id: UUID, highlight: UUID, note: String) {
        update(id) { item in
            guard let i = item.highlights.firstIndex(where: { $0.id == highlight }) else { return }
            item.highlights[i].note = note.isEmpty ? nil : note
        }
    }

    private func update(_ id: UUID, _ change: (inout ReadingItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        persist()
    }

    // MARK: Article content

    func articleURL(_ id: UUID) -> URL { articlesDir.appendingPathComponent("\(id.uuidString).html") }

    func articleHTML(_ id: UUID) -> String? { try? String(contentsOf: articleURL(id), encoding: .utf8) }

    func refetch(_ id: UUID) {
        update(id) { $0.contentError = nil }
        enqueueFetch(id, front: true)
    }

    private func extract(id: UUID, html: String, baseURL: URL) async {
        guard let article = await ArticleExtractor.shared.extract(html: html, baseURL: baseURL) else { return }
        storeArticle(id, article: article)
    }

    private func storeArticle(_ id: UUID, article: ArticleExtractor.Article) {
        try? FileManager.default.createDirectory(at: articlesDir, withIntermediateDirectories: true)
        guard (try? Data(article.html.utf8).write(to: articleURL(id), options: .atomic)) != nil else { return }
        update(id) { item in
            item.hasContent = true
            item.contentError = nil
            item.wordCount = article.words
            if item.title.isEmpty || item.title == item.url || item.title == item.host, !article.title.isEmpty { item.title = article.title }
            if item.author == nil, !article.byline.isEmpty { item.author = article.byline }
            if item.siteName == nil, !article.siteName.isEmpty { item.siteName = article.siteName }
            if item.summary == nil, !article.excerpt.isEmpty { item.summary = article.excerpt }
            if item.imageURL == nil, !article.image.isEmpty { item.imageURL = article.image }
        }
    }

    private func enqueueFetch(_ id: UUID, front: Bool = false) {
        fetchQueue.removeAll { $0 == id }
        if front { fetchQueue.insert(id, at: 0) } else { fetchQueue.append(id) }
        runFetches()
    }

    /// Fills in articles that arrived without text (links, CSV imports, old saves), one at a time.
    func fetchMissing() {
        for item in items where !item.hasContent && item.contentError == nil && item.location != .archive {
            if !fetchQueue.contains(item.id) { fetchQueue.append(item.id) }
        }
        runFetches()
    }

    private func runFetches() {
        guard !fetchRunning else { return }
        fetchRunning = true
        Task {
            while !fetchQueue.isEmpty {
                let id = fetchQueue.removeFirst()
                guard let item = item(id), !item.hasContent, let url = URL(string: item.url) else { continue }
                fetching.insert(id)
                let error = await fetchArticle(id, url: url)
                fetching.remove(id)
                if let error { update(id) { $0.contentError = error } }
            }
            fetchRunning = false
        }
    }

    private func fetchArticle(_ id: UUID, url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { return "The site said \(code)" }
            let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard type.isEmpty || type.contains("html") else { return "Not an article page" }
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            guard let article = await ArticleExtractor.shared.extract(html: html, baseURL: resp.url ?? url),
                  article.words >= 80 else { return "Couldn't find the article text" }
            storeArticle(id, article: article)
            return nil
        } catch {
            return "Couldn't reach the site"
        }
    }

    // MARK: Readwise import

    func setToken(_ token: String?) {
        ReaderKey.save(token)
        hasToken = ReaderKey.load() != nil
    }

    /// Pulls the whole Reader library (not the RSS feed) with its article HTML and
    /// highlights, through the token in the Keychain. Safe to run again: matched by
    /// Readwise id, then URL; local progress, location and highlights are kept.
    func importFromReadwise() {
        guard !importing, let token = ReaderKey.load() else { return }
        importing = true
        importStatus = "Connecting to Readwise…"
        Task {
            defer { importing = false }
            var cursor: String?
            var docs: [ReadwiseDocument] = []
            repeat {
                var c = URLComponents(string: "https://readwise.io/api/v3/list/")!
                c.queryItems = [URLQueryItem(name: "withHtmlContent", value: "true")]
                    + (cursor.map { [URLQueryItem(name: "pageCursor", value: $0)] } ?? [])
                var req = URLRequest(url: c.url!)
                req.timeoutInterval = 60
                req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    let http = resp as? HTTPURLResponse
                    switch http?.statusCode ?? 0 {
                    case 200:
                        let page = try ReadwiseImport.parseListPage(data)
                        docs += page.documents
                        cursor = page.nextCursor
                        importStatus = "Downloaded \(docs.filter { $0.item != nil }.count) documents…"
                    case 429:
                        let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30
                        importStatus = "Readwise asked to slow down; waiting \(Int(wait))s…"
                        try await Task.sleep(nanoseconds: UInt64((wait + 1) * 1e9))
                    case 401, 403:
                        importStatus = "Readwise refused the token (the trial may have closed API access). Export a CSV from Reader instead and import that."
                        return
                    case let code:
                        importStatus = "Readwise said \(code). Try again later, or import a CSV export."
                        return
                    }
                } catch {
                    importStatus = "Couldn't reach Readwise: \(error.localizedDescription)"
                    return
                }
            } while cursor != nil
            let (added, updated, highlights) = merge(docs)
            importStatus = "Imported from Readwise: \(added) new, \(updated) already here, \(highlights) highlights."
            fetchMissing()
        }
    }

    private func merge(_ docs: [ReadwiseDocument]) -> (added: Int, updated: Int, highlights: Int) {
        var added = 0, updated = 0
        var localByRW: [String: UUID] = [:]
        for d in docs {
            guard var incoming = d.item else { continue }
            let key = ReadingURL.key(incoming.url)
            let id: UUID
            if let i = items.firstIndex(where: { ($0.readwiseID != nil && $0.readwiseID == d.id) || ReadingURL.key($0.url) == key }) {
                items[i].readwiseID = d.id
                if items[i].tags.isEmpty { items[i].tags = incoming.tags }
                if items[i].author == nil { items[i].author = incoming.author }
                if items[i].source == "csv" || items[i].source == "readwise" {
                    items[i].location = incoming.location
                    items[i].progress = max(items[i].progress, incoming.progress)
                }
                id = items[i].id
                updated += 1
            } else {
                incoming.id = UUID()
                items.append(incoming)
                id = incoming.id
                added += 1
            }
            localByRW[d.id] = id
            if let html = d.html, item(id)?.hasContent != true {
                try? FileManager.default.createDirectory(at: articlesDir, withIntermediateDirectories: true)
                let clean = ArticleExtractor.stripScripts(html)
                if (try? Data(clean.utf8).write(to: articleURL(id), options: .atomic)) != nil {
                    let words = ArticleExtractor.wordCount(clean)
                    update(id) { $0.hasContent = true; $0.wordCount = $0.wordCount ?? words }
                }
            }
        }
        var highlights = 0
        for d in docs {
            guard let (parent, h) = d.highlight, let id = localByRW[parent],
                  let i = items.firstIndex(where: { $0.id == id }),
                  !items[i].highlights.contains(where: { $0.text == h.text }) else { continue }
            items[i].highlights.append(h)
            highlights += 1
        }
        persist()
        return (added, updated, highlights)
    }

    /// Reader's library CSV (Preferences → Export) or Readwise's highlights CSV.
    func importCSV(_ file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            importStatus = "Couldn't read \(file.lastPathComponent)"
            return
        }
        let result = ReadwiseImport.parseCSV(text)
        var added = 0
        for incoming in result.items {
            let key = ReadingURL.key(incoming.url)
            if let i = items.firstIndex(where: { ReadingURL.key($0.url) == key }) {
                if items[i].readwiseID == nil { items[i].readwiseID = incoming.readwiseID }
                if items[i].tags.isEmpty { items[i].tags = incoming.tags }
                continue
            }
            items.append(incoming)
            added += 1
        }
        var highlights = 0
        for (urlKey, hs) in result.highlightsByURL {
            guard let i = items.firstIndex(where: { ReadingURL.key($0.url) == urlKey }) else { continue }
            for h in hs where !items[i].highlights.contains(where: { $0.text == h.text }) { items[i].highlights.append(h); highlights += 1 }
        }
        for (title, hs) in result.highlightsByTitle {
            guard let i = items.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) else { continue }
            for h in hs where !items[i].highlights.contains(where: { $0.text == h.text }) { items[i].highlights.append(h); highlights += 1 }
        }
        persist()
        if result.items.isEmpty && highlights == 0 {
            importStatus = "Nothing to import in \(file.lastPathComponent): it needs a URL or Highlight column."
        } else {
            importStatus = "Imported \(file.lastPathComponent): \(added) new articles, \(highlights) highlights. Fetching article text…"
        }
        fetchMissing()
    }

    // MARK: Persistence

    /// Saves made through Readwise before 11/6 were recorded in `reader-saves.json`.
    private func migrateOldSaves() {
        let old = dir.deletingLastPathComponent().appendingPathComponent("reader-saves.json")
        guard let data = try? Data(contentsOf: old),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let iso = ISO8601DateFormatter()
        for r in rows {
            guard let url = r["url"] as? String, !items.contains(where: { ReadingURL.key($0.url) == ReadingURL.key(url) }) else { continue }
            items.append(ReadingItem(url: url, title: (r["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url,
                                     author: r["author"] as? String,
                                     savedAt: (r["savedAt"] as? String).flatMap(iso.date) ?? Date(),
                                     label: r["label"] as? String, wasFocus: r["wasFocus"] as? Bool,
                                     source: r["source"] as? String ?? "blocked"))
        }
        persist()
        try? FileManager.default.moveItem(at: old, to: old.appendingPathExtension("migrated"))
    }

    private func persist(soon: Bool = false) {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeNow() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (soon ? 2 : 0.05), execute: work)
    }

    private func writeNow() {
        guard let data = try? JSONEncoder.iso.encode(items) else { return }
        let url = libraryURL, folder = dir
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func flush() { persistWork?.cancel(); writeNow() }
}

/// The Readwise access token (readwise.io/access_token), in the login Keychain. Only
/// used to import the old Reader library now.
enum ReaderKey {
    static let service = "com.magnus.focus.readwise"

    static func load() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func save(_ token: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
