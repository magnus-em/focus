import Foundation
import Combine
import FocusCore

/// Your goals (`Goals.Document`), synced through iCloud key-value storage so
/// the phone sees the same list. Edits append to the history.
@MainActor
final class GoalsStore: ObservableObject {
    static let shared = GoalsStore()
    @Published private(set) var doc: Goals.Document
    let changed = PassthroughSubject<Void, Never>()
    private var observer: NSObjectProtocol?

    private init() {
        if let d = Goals.Document.decode(UserDefaults.standard.string(forKey: Goals.key)) {
            doc = d
        } else {
            doc = Goals.seed()
            if let s = doc.encoded() { SyncedDefaults.shared.set(s, forKey: Goals.key) }
        }
        observer = NotificationCenter.default.addObserver(forName: SyncedDefaults.didImportRemoteChanges, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let d = Goals.Document.decode(UserDefaults.standard.string(forKey: Goals.key)), d != self.doc else { return }
                self.doc = d
                self.changed.send()
            }
        }
    }

    var active: [Goals.Goal] { doc.active }
    var avoided: [Goals.Goal] { doc.active.filter(\.avoided) }

    func save(_ goals: [Goals.Goal]) {
        var next = doc
        let now = Date()
        let old = Dictionary(uniqueKeysWithValues: doc.goals.map { ($0.id, $0) })
        next.goals = goals.map { g in
            var g = g
            if let o = old[g.id], o != g { g.updatedAt = now }
            return g
        }
        let lines = Goals.describe(from: doc, to: next)
        guard !lines.isEmpty || next.goals != doc.goals else { return }
        next.history += lines.map { Goals.Change(at: now, summary: $0) }
        next.history = Array(next.history.suffix(200))
        commit(next)
    }

    func markReviewed() {
        var next = doc
        next.reviewedAt = Date()
        next.history.append(Goals.Change(at: Date(), summary: "Reviewed goals, no changes"))
        commit(next)
    }

    private func commit(_ next: Goals.Document) {
        doc = next
        if let s = next.encoded() { SyncedDefaults.shared.set(s, forKey: Goals.key) }
        changed.send()
    }
}
