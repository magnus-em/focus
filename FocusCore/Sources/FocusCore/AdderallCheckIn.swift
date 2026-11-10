import Foundation

/// End-of-day answer to "how did Adderall treat you today?". Every day gets
/// the core sliders (off days are the baseline); dose days add how long it
/// lasted, the comedown and whether it was worth it.
public struct AdderallCheckIn: Codable, Equatable, Sendable, Identifiable {
    public var day: String
    public var tookDose: Bool
    public var focus: Int
    public var mood: Int
    public var anxiety: Int
    public var appetite: Int
    /// Last night, so it reads as the effect of the day before.
    public var sleep: Int
    public var hoursWorked: Double?
    public var comedown: Int?
    public var worthIt: Int?
    public var effects: [String]
    public var note: String
    public var updatedAt: Date

    public var id: String { day }

    public init(day: String, tookDose: Bool, focus: Int = 5, mood: Int = 5, anxiety: Int = 2, appetite: Int = 7,
                sleep: Int = 6, hoursWorked: Double? = nil, comedown: Int? = nil, worthIt: Int? = nil,
                effects: [String] = [], note: String = "", updatedAt: Date = Date()) {
        self.day = day; self.tookDose = tookDose; self.focus = focus; self.mood = mood; self.anxiety = anxiety
        self.appetite = appetite; self.sleep = sleep; self.hoursWorked = hoursWorked; self.comedown = comedown
        self.worthIt = worthIt; self.effects = effects; self.note = note; self.updatedAt = updatedAt
    }

    public static let sideEffects = ["Racing heart", "Headache", "Irritable", "Jaw clenching", "Dry mouth", "Nausea", "Tunnel vision"]

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// Newest edit of each day wins.
    public static func merge(_ a: [String: AdderallCheckIn], _ b: [String: AdderallCheckIn]) -> [String: AdderallCheckIn] {
        a.merging(b) { $1.updatedAt > $0.updatedAt ? $1 : $0 }
    }
}

public enum CheckInMetric: String, CaseIterable, Identifiable, Sendable {
    case focus, mood, anxiety, appetite, sleep, hoursWorked, comedown, worthIt

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .focus: return "Focus"
        case .mood: return "Mood"
        case .anxiety: return "Anxious / on edge"
        case .appetite: return "Appetite"
        case .sleep: return "Sleep last night"
        case .hoursWorked: return "Hours it worked"
        case .comedown: return "Comedown"
        case .worthIt: return "Worth it"
        }
    }

    public var question: String {
        switch self {
        case .focus: return "How well could you focus when you sat down to work?"
        case .mood: return "How was your mood overall?"
        case .anxiety: return "How anxious, jittery or on edge did you feel?"
        case .appetite: return "How was your appetite? Did you eat normally?"
        case .sleep: return "How did you sleep last night?"
        case .hoursWorked: return "Roughly how many hours did you feel it working?"
        case .comedown: return "How rough was it as it wore off?"
        case .worthIt: return "Looking back on today, was it worth taking?"
        }
    }

    public var low: String {
        switch self {
        case .focus: return "Scattered"
        case .mood: return "Low"
        case .anxiety: return "Calm"
        case .appetite: return "None"
        case .sleep: return "Awful"
        case .hoursWorked: return "0 h"
        case .comedown: return "None"
        case .worthIt: return "No"
        }
    }

    public var high: String {
        switch self {
        case .focus: return "Locked in"
        case .mood: return "Great"
        case .anxiety: return "Very"
        case .appetite: return "Normal"
        case .sleep: return "Great"
        case .hoursWorked: return "12 h"
        case .comedown: return "Rough"
        case .worthIt: return "Clearly"
        }
    }

    public var doseOnly: Bool { [.hoursWorked, .comedown, .worthIt].contains(self) }
    /// Higher is worse, so trends color the other way.
    public var higherIsWorse: Bool { self == .anxiety || self == .comedown }
    public var maxValue: Double { self == .hoursWorked ? 12 : 10 }

    public func value(_ c: AdderallCheckIn) -> Double? {
        switch self {
        case .focus: return Double(c.focus)
        case .mood: return Double(c.mood)
        case .anxiety: return Double(c.anxiety)
        case .appetite: return Double(c.appetite)
        case .sleep: return Double(c.sleep)
        case .hoursWorked: return c.tookDose ? c.hoursWorked : nil
        case .comedown: return c.tookDose ? c.comedown.map(Double.init) : nil
        case .worthIt: return c.tookDose ? c.worthIt.map(Double.init) : nil
        }
    }
}

public struct CheckInSummary: Equatable, Sendable {
    public struct Split: Equatable, Sendable {
        public let metric: CheckInMetric
        public let dose: Double?
        public let doseDays: Int
        public let off: Double?
        public let offDays: Int
        /// Same metric over the window before this one, dose days only.
        public let previous: Double?
    }

    public let checkIns: Int
    public let doseDays: Int
    public let splits: [Split]
    /// Side effect → dose days it was reported on.
    public let effects: [(name: String, days: Int)]

    public static func == (a: CheckInSummary, b: CheckInSummary) -> Bool {
        a.checkIns == b.checkIns && a.doseDays == b.doseDays && a.splits == b.splits
            && a.effects.map(\.name) == b.effects.map(\.name) && a.effects.map(\.days) == b.effects.map(\.days)
    }

    /// `days` ending on `end` (inclusive). Sleep is the next morning's answer,
    /// so it's credited to the day before when splitting dose vs off.
    public static func make(_ all: [String: AdderallCheckIn], days: Int, end: Date, calendar: Calendar = .current) -> CheckInSummary {
        let endDay = calendar.startOfDay(for: end)
        func window(_ offset: Int) -> [AdderallCheckIn] {
            (0..<days).compactMap { back in
                calendar.date(byAdding: .day, value: -(back + offset), to: endDay).flatMap { all[AdderallCheckIn.dayKey($0, calendar: calendar)] }
            }
        }
        let current = window(0), before = window(days)
        func sleepAfter(_ c: AdderallCheckIn) -> Double? {
            guard let d = AdderallCheckIn.date(c.day, calendar: calendar),
                  let next = calendar.date(byAdding: .day, value: 1, to: d) else { return nil }
            return all[AdderallCheckIn.dayKey(next, calendar: calendar)].map { Double($0.sleep) }
        }
        func values(_ m: CheckInMetric, _ list: [AdderallCheckIn]) -> [Double] {
            list.compactMap { m == .sleep ? sleepAfter($0) : m.value($0) }
        }
        func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        let dose = current.filter(\.tookDose), off = current.filter { !$0.tookDose }
        let splits = CheckInMetric.allCases.map { m in
            let dv = values(m, dose), ov = m.doseOnly ? [] : values(m, off)
            return Split(metric: m, dose: avg(dv), doseDays: dv.count, off: avg(ov), offDays: ov.count,
                         previous: avg(values(m, before.filter(\.tookDose))))
        }
        var counts: [String: Int] = [:]
        for c in dose { for e in Set(c.effects) { counts[e, default: 0] += 1 } }
        let effects = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { (name: $0.key, days: $0.value) }
        return CheckInSummary(checkIns: current.count, doseDays: dose.count, splits: splits, effects: effects)
    }
}
