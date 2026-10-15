import Foundation
import Combine
import FocusCore

@MainActor
final class ScreenJournalStore: ObservableObject {
    static let shared = ScreenJournalStore()
    static let enabledKey = "screenJournalEnabled"
    @Published var enabled: Bool {
        didSet { worker.invalidate(); CoachEpisodeStore.shared.invalidate(); UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var lastError: String?
    private let worker: ScreenJournalWriter
    private var retentionTimer: Timer?
    var token: Int { worker.token }
    var onStored: ((ScreenJournal.Row) -> Void)?

    init(directory: URL? = nil) {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        worker = ScreenJournalWriter(directory: directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focus/journal", isDirectory: true))
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do { try await self.worker.prune() } catch { self.lastError = error.localizedDescription }
            }
        }
        Task { do { try await worker.prune() } catch { lastError = error.localizedDescription } }
    }
    func invalidate() { worker.invalidate(); CoachEpisodeStore.shared.invalidate() }
    func record(_ row: ScreenJournal.Row, token: Int) {
        guard enabled, allowed(row.bundle) else { return }
        Task {
            guard enabled, allowed(row.bundle), token == worker.token else { return }
            do {
                let stored = try await worker.append(row, token: token)
                guard stored, enabled, allowed(row.bundle), token == worker.token else { return }
                lastError = nil
                onStored?(row)
            }
            catch { lastError = "Couldn't save screen text: \(error.localizedDescription)" }
        }
    }
    func deleteAll() {
        worker.invalidate()
        CoachEpisodeStore.shared.delete()
        Task { do { try await worker.deleteAll(); lastError = nil } catch { lastError = error.localizedDescription } }
    }
    func delete(bundle: String) {
        worker.invalidate()
        CoachEpisodeStore.shared.delete(bundle: bundle)
        Task { do { try await worker.delete(bundle: bundle); lastError = nil } catch { lastError = error.localizedDescription } }
    }
    private func allowed(_ bundle: String) -> Bool {
        !ScreenWatcher.privateApps.contains(bundle) && ScreenWatcher.userIgnored[bundle] == nil && bundle != ScreenWatcher.ownBundle
    }
}
