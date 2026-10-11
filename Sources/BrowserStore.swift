import Foundation
import FocusCore
import SwiftData

struct BlockEvent: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let domain: String
    let label: String
    let wasFocus: Bool
    let reason: String
    let bypassed: Bool
}

struct BrowsingSpan: Identifiable, Equatable {
    let id: UUID
    let start: Date
    let end: Date
    let domain: String
    var seconds: TimeInterval { end.timeIntervalSince(start) }
}

/// Data reported by the Chrome extension through `BrowserBridge`.
class BrowserStore: ObservableObject {
    @Published private(set) var blocks: [BlockEvent] = []
    @Published private(set) var spans: [BrowsingSpan] = []

    private let context: ModelContext
    /// Same-domain spans closer than this are one visit.
    private static let mergeGap: TimeInterval = 90
    private static let keepDays = 120

    init(container: ModelContainer) {
        self.context = ModelContext(container)
        prune()
        refresh()
    }

    func refresh() {
        var b = FetchDescriptor<StoredBlockEvent>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        b.includePendingChanges = true
        blocks = ((try? context.fetch(b)) ?? []).map {
            BlockEvent(id: $0.id, date: $0.date, domain: $0.domain, label: $0.label,
                       wasFocus: $0.wasFocus, reason: $0.reason, bypassed: $0.bypassed)
        }
        var s = FetchDescriptor<StoredBrowsingSpan>(sortBy: [SortDescriptor(\.start)])
        s.includePendingChanges = true
        spans = ((try? context.fetch(s)) ?? []).map {
            BrowsingSpan(id: $0.id, start: $0.start, end: $0.end, domain: $0.domain)
        }
    }

    // MARK: - Ingest

    enum Event {
        case block(id: UUID, date: Date, domain: String, label: String, wasFocus: Bool)
        case reason(id: UUID, reason: String)
        case bypass(id: UUID, reason: String)
        case span(start: Date, end: Date, domain: String)
    }

    func ingest(_ events: [Event]) {
        guard !events.isEmpty else { return }
        for e in events {
            switch e {
            case let .block(id, date, domain, label, wasFocus):
                guard storedBlock(id) == nil else { continue }
                let m = StoredBlockEvent()
                m.id = id; m.date = date; m.domain = domain; m.label = label; m.wasFocus = wasFocus
                context.insert(m)
            case let .reason(id, reason):
                storedBlock(id)?.reason = reason
            case let .bypass(id, reason):
                guard let m = storedBlock(id) else { continue }
                m.bypassed = true
                if !reason.isEmpty { m.reason = reason }
            case let .span(start, end, domain):
                insertSpan(start: start, end: end, domain: domain)
            }
            // Spans merge against earlier rows, so each insert must be visible to the next fetch.
            try? context.save()
        }
        refresh()
    }

    private func storedBlock(_ id: UUID) -> StoredBlockEvent? {
        var d = FetchDescriptor<StoredBlockEvent>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        d.includePendingChanges = true
        return try? context.fetch(d).first
    }

    private func insertSpan(start: Date, end: Date, domain: String) {
        guard end > start, !domain.isEmpty else { return }
        let lower = start.addingTimeInterval(-Self.mergeGap)
        let upper = end.addingTimeInterval(Self.mergeGap)
        var d = FetchDescriptor<StoredBrowsingSpan>(
            predicate: #Predicate { $0.domain == domain && $0.end >= lower && $0.start <= upper },
            sortBy: [SortDescriptor(\.start)]
        )
        d.includePendingChanges = true
        let near = (try? context.fetch(d)) ?? []
        guard let first = near.first else {
            let m = StoredBrowsingSpan()
            m.start = start; m.end = end; m.domain = domain
            context.insert(m)
            return
        }
        first.start = min(first.start, start)
        first.end = max(near.map(\.end).max() ?? end, end)
        for extra in near.dropFirst() { context.delete(extra) }
    }

    private func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.keepDays, to: Date()) else { return }
        try? context.delete(model: StoredBrowsingSpan.self, where: #Predicate { $0.end < cutoff })
        try? context.save()
    }

    // MARK: - Queries

    func blocks(on day: Date) -> [BlockEvent] {
        let cal = Calendar.current
        return blocks.filter { cal.isDate($0.date, inSameDayAs: day) }
    }

    func blockCount(since start: Date) -> Int { blocks.filter { $0.date >= start }.count }

    /// Spans clipped to `[start, end)`.
    func spans(from start: Date, to end: Date) -> [BrowsingSpan] {
        spans.compactMap { s in
            let a = max(s.start, start), b = min(s.end, end)
            return b > a ? BrowsingSpan(id: s.id, start: a, end: b, domain: s.domain) : nil
        }
    }

    func secondsByDomain(_ spans: [BrowsingSpan]) -> [(domain: String, seconds: TimeInterval)] {
        Dictionary(grouping: spans, by: \.domain)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.seconds }) }
            .sorted { $0.1 > $1.1 }
    }

    /// Browsing time inside the given intervals (e.g. today's focus sessions).
    func spans(within intervals: [DateInterval]) -> [BrowsingSpan] {
        intervals.flatMap { spans(from: $0.start, to: $0.end) }
    }

    static func countByDomain(_ events: [BlockEvent]) -> [(domain: String, count: Int)] {
        Dictionary(grouping: events, by: \.domain)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }
}
