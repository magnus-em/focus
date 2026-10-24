import Foundation
import Security

/// Read-later saves into Readwise Reader, starting with pages the site blocker
/// stopped. Every save is also kept locally in `Focus/reader-saves.json`, so
/// pages saved before a token was set (or while offline) go up later and Focus
/// can tell when articles were collected during focus.
@MainActor
final class ReaderStore: ObservableObject {
    static let shared = ReaderStore()

    struct Save: Codable, Identifiable, Equatable {
        enum Status: String, Codable { case pending, saved, failed }
        var id: UUID
        var url: String
        var title: String
        var savedAt: Date
        var label: String
        var wasFocus: Bool
        var source: String
        var status: Status
        var error: String?
        var readerURL: String?
    }

    @Published private(set) var saves: [Save] = []
    @Published private(set) var hasToken = ReaderKey.load() != nil

    private let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Focus/reader-saves.json")
    private var uploading = false

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.iso.decode([Save].self, from: data) {
            saves = decoded
        }
    }

    var pendingCount: Int { saves.filter { $0.status != .saved }.count }

    func setToken(_ token: String?) {
        ReaderKey.save(token)
        hasToken = ReaderKey.load() != nil
        if hasToken { Task { await uploadPending() } }
    }

    /// Returns "saved", "queued" (no token or Reader unreachable) or an error.
    func save(url: String, title: String, label: String, wasFocus: Bool, source: String) async -> (status: String, error: String?) {
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
            return ("error", "Not a web page")
        }
        if let i = saves.firstIndex(where: { $0.url == url }), saves[i].status == .saved {
            return ("saved", nil)
        }
        let item = Save(id: UUID(), url: url, title: title, savedAt: Date(), label: label, wasFocus: wasFocus,
                        source: source, status: .pending)
        saves.removeAll { $0.url == url }
        saves.append(item)
        persist()
        guard let token = ReaderKey.load() else { return ("queued", nil) }
        await upload(item.id, token: token)
        let done = saves.first { $0.id == item.id }
        switch done?.status {
        case .saved: return ("saved", nil)
        case .failed: return ("error", done?.error)
        default: return ("queued", nil)
        }
    }

    func uploadPending() async {
        guard !uploading, let token = ReaderKey.load() else { return }
        uploading = true
        defer { uploading = false }
        for id in saves.filter({ $0.status == .pending }).map(\.id) {
            await upload(id, token: token)
        }
    }

    func retryFailed() {
        for i in saves.indices where saves[i].status == .failed { saves[i].status = .pending; saves[i].error = nil }
        persist()
        Task { await uploadPending() }
    }

    private func upload(_ id: UUID, token: String) async {
        guard let item = saves.first(where: { $0.id == id }) else { return }
        var req = URLRequest(url: URL(string: "https://readwise.io/api/v3/save/")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["url": item.url, "location": "later", "saved_using": "Focus",
                                   "tags": item.source == "blocked" ? ["focus-blocked"] : ["focus"]]
        if !item.title.isEmpty { body["title"] = item.title }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let result: (Save.Status, String?, String?)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch code {
            case 200, 201: result = (.saved, nil, obj?["url"] as? String)
            case 401, 403: result = (.failed, "Readwise rejected the token", nil)
            case 429, 500...: result = (.pending, nil, nil)
            default: result = (.failed, "Readwise said \(code)", nil)
            }
        } catch {
            result = (.pending, nil, nil)
        }
        guard let i = saves.firstIndex(where: { $0.id == id }) else { return }
        saves[i].status = result.0
        saves[i].error = result.1
        saves[i].readerURL = result.2
        persist()
    }

    private func persist() {
        let cutoff = Date().addingTimeInterval(-180 * 86400)
        saves.removeAll { $0.status == .saved && $0.savedAt < cutoff }
        let url = fileURL
        guard let data = try? JSONEncoder.iso.encode(saves) else { return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// The user's Readwise access token (readwise.io/access_token), in the login Keychain.
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
