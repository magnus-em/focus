import Foundation

public enum HealthTracker: String, CaseIterable, Identifiable, Sendable {
    case fap, adderall

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fap: return "Jerk"
        case .adderall: return "Adderall"
        }
    }

    public var kinds: [HealthKind] { HealthKind.allCases.filter { $0.tracker == self } }

    /// Fap counts occurrences; Adderall sums milligrams.
    public var unit: String { self == .adderall ? "mg" : "" }
}

/// `StoredHealthEvent.kind` values. Add a case for a new habit or dose; no schema change.
public enum HealthKind: String, CaseIterable, Identifiable, Sendable {
    case fap
    case adderallIR10, adderallIR20, adderallXR20

    public var id: String { rawValue }

    public var tracker: HealthTracker {
        switch self {
        case .fap: return .fap
        case .adderallIR10, .adderallIR20, .adderallXR20: return .adderall
        }
    }

    public var displayName: String {
        switch self {
        case .fap: return "Jerk"
        case .adderallIR10: return "IR 10 mg"
        case .adderallIR20: return "IR 20 mg"
        case .adderallXR20: return "XR 20 mg"
        }
    }

    public var shortName: String {
        switch self {
        case .fap: return "Jerk"
        case .adderallIR10: return "IR 10"
        case .adderallIR20: return "IR 20"
        case .adderallXR20: return "XR 20"
        }
    }

    public var amount: Int {
        switch self {
        case .fap: return 1
        case .adderallIR10: return 10
        case .adderallIR20, .adderallXR20: return 20
        }
    }
}
