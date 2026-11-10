import Foundation
import Combine
import FocusCore

/// Applications seen on screen (`RecruitingEvidence`), in
/// `Focus/recruiting/applications.jsonl`. Fed by every stored screen reading.
@MainActor
final class RecruitingStore: ObservableObject {
    static let shared = RecruitingStore()
    @Published private(set) var applications: [RecruitingEvidence.Application] = []
    private var sub: AnyCancellable?

    nonisolated static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/recruiting/applications.jsonl")
    }

    private init() {
        applications = Self.load()
    }

    func start() {
        guard sub == nil else { return }
        sub = ScreenJournalStore.shared.didStore.receive(on: DispatchQueue.main).sink { [weak self] row in
            guard let self, let text = row.text, row.privacy == .notBrowser || row.privacy == .regular,
                  let app = RecruitingEvidence.application(title: row.title, url: row.url, text: text, app: row.app, at: row.at),
                  !self.applications.contains(where: { $0.id == app.id }) else { return }
            self.add(app)
        }
    }

    func add(_ app: RecruitingEvidence.Application) {
        applications.append(app)
        applications = RecruitingEvidence.deduplicated(applications)
        guard let line = try? JSONEncoder().encode(app) else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line + Data("\n".utf8)); try? h.close()
        } else {
            try? (line + Data("\n".utf8)).write(to: url, options: .atomic)
        }
    }

    func remove(_ id: String) {
        applications.removeAll { $0.id == id }
        let data = applications.compactMap { try? JSONEncoder().encode($0) }.reduce(Data()) { $0 + $1 + Data("\n".utf8) }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    nonisolated static func load() -> [RecruitingEvidence.Application] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return RecruitingEvidence.deduplicated(text.split(separator: "\n").compactMap { try? dec.decode(RecruitingEvidence.Application.self, from: Data($0.utf8)) })
    }
}
