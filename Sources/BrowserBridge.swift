import Foundation
import Network
import FocusCore

/// Loopback HTTP endpoint for the Chrome extension in `ChromeExtension/`.
///
///   GET  /state   → what to block right now (`State`)
///   POST /events  → `{ "events": [...] }` block hits, reasons, bypasses, browsing spans
///   POST /tab     → `{ "url", "title" }` the focused tab, for the screen watcher
///
/// Only browsers attach an `Origin`, and a web page can't forge one, so any
/// request whose Origin isn't the extension is refused. Local processes are
/// trusted (they could write the store directly anyway).
final class BrowserBridge: ObservableObject {
    static let shared = BrowserBridge()
    static let port: UInt16 = 47821
    /// Pinned by the `key` in ChromeExtension/manifest.json.
    static let extensionOrigin = "chrome-extension://dljnfclilnaccokglnomfjlbbanapflo"

    struct State: Encodable {
        let blocking: Bool
        let domains: [String]
        let label: String
        let isFocus: Bool
        let onBreak: Bool
        let paused: Bool
        let bypassAllowed: Bool
        let sessionStart: Double?
        let todayBlocked: Int
    }

    @Published private(set) var lastContact: Date?

    struct Tab { let url: String; let title: String; let at: Date }
    /// Focused Chrome tab (non-incognito), kept in memory only.
    @MainActor private(set) var activeTab: Tab?
    @MainActor private(set) var focusReport: BrowserWindowPrivacy.Report?
    @Published private(set) var listenError: String?

    var stateProvider: (() -> State)?
    var onEvents: (([BrowserStore.Event]) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.magnus.focus.browser-bridge")

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                guard case .failed(let err) = state else { return }
                DispatchQueue.main.async { self?.listenError = err.localizedDescription }
                l.cancel()
                self?.listener = nil
                self?.queue.asyncAfter(deadline: .now() + 10) { self?.start() }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            listenError = error.localizedDescription
        }
    }

    // MARK: - HTTP

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        /// nil until the full request (headers + Content-Length body) has arrived.
        init?(_ data: Data) {
            guard let sep = data.range(of: Data("\r\n\r\n".utf8)),
                  let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
            var lines = head.components(separatedBy: "\r\n")
            let parts = lines.removeFirst().split(separator: " ")
            guard parts.count >= 2 else { return nil }
            var h: [String: String] = [:]
            for line in lines {
                guard let i = line.firstIndex(of: ":") else { continue }
                h[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(h["content-length"] ?? "0") ?? 0
            let body = data[sep.upperBound...]
            guard body.count >= length else { return nil }
            method = String(parts[0])
            path = String(parts[1].split(separator: "?").first ?? "")
            headers = h
            self.body = Data(body.prefix(length))
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Request(buf) {
                self.handle(req, conn)
            } else if done || error != nil || buf.count > 4 * 1024 * 1024 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func handle(_ req: Request, _ conn: NWConnection) {
        if let origin = req.headers["origin"], origin != Self.extensionOrigin {
            return respond(conn, status: "403 Forbidden", json: Data(#"{"error":"origin"}"#.utf8))
        }
        switch (req.method, req.path) {
        case ("OPTIONS", _):
            respond(conn, status: "204 No Content", json: nil)
        case ("GET", "/state"):
            DispatchQueue.main.async {
                self.lastContact = Date()
                let body = self.stateProvider.flatMap { try? JSONEncoder().encode($0()) } ?? Data("{}".utf8)
                self.queue.async { self.respond(conn, status: "200 OK", json: body) }
            }
        case ("POST", "/tab"):
            let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
            DispatchQueue.main.async {
                self.lastContact = Date()
                MainActor.assumeIsolated {
                    if let ts = obj?["ts"] as? Double, let window = obj?["focusedWindowId"] as? Int,
                       let incognito = obj?["incognito"] as? Bool {
                        let at = Date(timeIntervalSince1970: ts / 1000)
                        if abs(at.timeIntervalSinceNow) <= 10, at > (self.focusReport?.at ?? .distantPast) {
                            self.focusReport = .init(windowID: window, incognito: incognito, title: obj?["title"] as? String ?? "", at: at)
                            if window >= 0, !incognito, let url = obj?["url"] as? String, !url.isEmpty {
                                self.activeTab = Tab(url: url, title: obj?["title"] as? String ?? "", at: at)
                            } else { self.activeTab = nil }
                        }
                    } else if let url = obj?["url"] as? String, !url.isEmpty {
                        self.activeTab = Tab(url: url, title: obj?["title"] as? String ?? "", at: Date())
                        self.focusReport = nil
                    }
                }
                self.queue.async { self.respond(conn, status: "200 OK", json: Data(#"{"ok":true}"#.utf8)) }
            }
        case ("POST", "/events"):
            let events = Self.decodeEvents(req.body)
            DispatchQueue.main.async {
                self.lastContact = Date()
                self.onEvents?(events)
                self.queue.async { self.respond(conn, status: "200 OK", json: Data(#"{"ok":true}"#.utf8)) }
            }
        default:
            respond(conn, status: "404 Not Found", json: Data(#"{"error":"not found"}"#.utf8))
        }
    }

    private func respond(_ conn: NWConnection, status: String, json: Data?) {
        let body = json ?? Data()
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: \(Self.extensionOrigin)\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Access-Control-Allow-Private-Network: true\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Decoding

    private static func decodeEvents(_ body: Data) -> [BrowserStore.Event] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let raw = root["events"] as? [[String: Any]] else { return [] }
        func date(_ v: Any?) -> Date? { (v as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
        func uuid(_ v: Any?) -> UUID? { (v as? String).flatMap(UUID.init) }
        return raw.compactMap { e in
            switch e["kind"] as? String {
            case "block":
                guard let id = uuid(e["id"]), let d = date(e["date"]), let domain = e["domain"] as? String else { return nil }
                return .block(id: id, date: d, domain: domain,
                              label: e["label"] as? String ?? "", wasFocus: e["isFocus"] as? Bool ?? false)
            case "reason":
                guard let id = uuid(e["id"]) else { return nil }
                return .reason(id: id, reason: e["reason"] as? String ?? "")
            case "bypass":
                guard let id = uuid(e["id"]) else { return nil }
                return .bypass(id: id, reason: e["reason"] as? String ?? "")
            case "span":
                guard let a = date(e["start"]), let b = date(e["end"]), let domain = e["domain"] as? String else { return nil }
                return .span(start: a, end: b, domain: domain)
            default:
                return nil
            }
        }
    }
}
