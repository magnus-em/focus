import Foundation
import SwiftData

// MARK: - Stored types
//
// SwiftData @Model classes mirroring the value-type models. Stored classes
// keep raw string scalars instead of enums so that CloudKit-compatible defaults
// and forward-compat decoding are trivial.
//
// CloudKit compatibility rules followed:
//   - No @Attribute(.unique)
//   - All properties have default values (or are optional)
//   - No required relationships
//
// `init()` is the parameterless initializer required by SwiftData; convenience
// inits take the value-type for one-shot construction during migration.

@Model
public final class StoredWorkSession {
    public var id: UUID = UUID()
    public var startTime: Date = Date()
    public var durationMinutes: Double = 0
    public var typeRaw: String = WorkSession.SessionType.work.rawValue
    public var label: String? = nil
    public var breakKindsRaw: [String] = []

    public init() {}

    public convenience init(value: WorkSession) {
        self.init()
        self.id = value.id
        self.startTime = value.startTime
        self.durationMinutes = value.durationMinutes
        self.typeRaw = value.type.rawValue
        self.label = value.label
        self.breakKindsRaw = value.breakKinds?.map(\.rawValue) ?? []
    }

    public var type: WorkSession.SessionType {
        get { WorkSession.SessionType(rawValue: typeRaw) ?? .work }
        set { typeRaw = newValue.rawValue }
    }

    public var isFocus: Bool { type == .work && !FocusCategories.isLife(label) }

    public var breakKinds: [BreakKind]? {
        get { breakKindsRaw.isEmpty ? nil : breakKindsRaw.compactMap { BreakKind(rawValue: $0) } }
        set { breakKindsRaw = newValue?.map(\.rawValue) ?? [] }
    }

    public var asValue: WorkSession {
        WorkSession(id: id, startTime: startTime, durationMinutes: durationMinutes,
                    type: type, label: label, breakKinds: breakKinds)
    }
}

@Model
public final class StoredProblem {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var title: String = ""
    public var domainRaw: String = ProblemDomain.quant.rawValue
    public var categories: [String] = []
    public var difficultyRaw: String = ProblemDifficulty.medium.rawValue
    public var needsReview: Bool = false
    public var confidenceRaw: String = Confidence.solid.rawValue
    public var source: String = ""
    public var notes: String = ""
    public var urlString: String = ""
    public var solveMinutes: Int? = nil

    public init() {}

    public convenience init(value: ProblemEntry) {
        self.init()
        self.id = value.id
        self.date = value.date
        self.title = value.title
        self.domainRaw = value.domain.rawValue
        self.categories = value.categories
        self.difficultyRaw = value.difficulty.rawValue
        self.needsReview = value.needsReview
        self.confidenceRaw = value.confidence.rawValue
        self.source = value.source
        self.notes = value.notes
        self.urlString = value.url
        self.solveMinutes = value.solveMinutes
    }

    public var domain: ProblemDomain {
        get { ProblemDomain(rawValue: domainRaw) ?? .quant }
        set { domainRaw = newValue.rawValue }
    }

    public var difficulty: ProblemDifficulty {
        get { ProblemDifficulty(rawValue: difficultyRaw) ?? .medium }
        set { difficultyRaw = newValue.rawValue }
    }

    public var confidence: Confidence {
        get { Confidence(rawValue: confidenceRaw) ?? .solid }
        set { confidenceRaw = newValue.rawValue }
    }

    public var asValue: ProblemEntry {
        ProblemEntry(id: id, date: date, title: title, domain: domain,
                     categories: categories, difficulty: difficulty,
                     source: source, needsReview: needsReview, confidence: confidence,
                     notes: notes, url: urlString, solveMinutes: solveMinutes)
    }
}

@Model
public final class StoredHomework {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var title: String = ""
    public var source: String = ""
    public var difficultyRaw: String = ProblemDifficulty.medium.rawValue
    public var confidenceRaw: String = Confidence.solid.rawValue
    public var usedAI: Bool = false
    public var notes: String = ""
    public var urlString: String = ""
    /// Optional link back to a catalog problem (e.g. Stat 110 HW2 #3).
    /// Nil for manually-entered homework. See `Stat110Catalog`.
    public var catalogID: String? = nil
    /// Mirrors ProblemEntry.needsReview — drives the homework review queue.
    public var needsReview: Bool = false
    /// User-set "review again on this date". Overrides the confidence-driven
    /// schedule (`reviewDueDate`) computed in HomeworkProblem.
    public var reviewOverrideDate: Date? = nil

    public init() {}

    public convenience init(value: HomeworkProblem) {
        self.init()
        self.id = value.id
        self.date = value.date
        self.title = value.title
        self.source = value.source
        self.difficultyRaw = value.difficulty.rawValue
        self.confidenceRaw = value.confidence.rawValue
        self.usedAI = value.usedAI
        self.notes = value.notes
        self.urlString = value.url
        self.catalogID = value.catalogID
        self.needsReview = value.needsReview
        self.reviewOverrideDate = value.reviewOverrideDate
    }

    public var difficulty: ProblemDifficulty {
        get { ProblemDifficulty(rawValue: difficultyRaw) ?? .medium }
        set { difficultyRaw = newValue.rawValue }
    }

    public var confidence: Confidence {
        get { Confidence(rawValue: confidenceRaw) ?? .solid }
        set { confidenceRaw = newValue.rawValue }
    }

    public var asValue: HomeworkProblem {
        HomeworkProblem(id: id, date: date, title: title, source: source,
                        difficulty: difficulty, confidence: confidence,
                        usedAI: usedAI, notes: notes, url: urlString,
                        catalogID: catalogID, needsReview: needsReview,
                        reviewOverrideDate: reviewOverrideDate)
    }
}

@Model
public final class StoredDayRecord {
    public var id: UUID = UUID()
    public var calendarDay: Date = Date()
    public var dayStart: Date? = nil
    public var dayEnd: Date? = nil
    public var commitmentText: String? = nil
    public var commitmentFulfilled: Bool? = nil

    public init() {}

    public convenience init(value: DayRecord) {
        self.init()
        self.id = value.id
        self.calendarDay = value.calendarDay
        self.dayStart = value.dayStart
        self.dayEnd = value.dayEnd
        self.commitmentText = value.commitmentText
        self.commitmentFulfilled = value.commitmentFulfilled
    }

    public var asValue: DayRecord {
        DayRecord(id: id, calendarDay: calendarDay, dayStart: dayStart, dayEnd: dayEnd,
                  commitmentText: commitmentText, commitmentFulfilled: commitmentFulfilled)
    }
}

@Model
public final class StoredScratchItem {
    public var id: UUID = UUID()
    public var text: String = ""
    public var isChecked: Bool = false
    public var order: Int = 0

    public init() {}

    public convenience init(value: ScratchItem, order: Int = 0) {
        self.init()
        self.id = value.id
        self.text = value.text
        self.isChecked = value.isChecked
        self.order = order
    }

    public var asValue: ScratchItem {
        ScratchItem(id: id, text: text, isChecked: isChecked)
    }
}

/// Shared live-timer state. There's at most one of these — both Mac and iPad
/// read + write the same record so they can mirror the running timer.
///
/// "Anchored time" model: when the timer is running, `endTime` is when it
/// would naturally complete; remaining is computed from wall clock.
/// When paused, `remainingSeconds` holds the value at pause moment.
/// `updatedAt` is the conflict-resolution tiebreaker (last write wins).
@Model
public final class StoredTimerState {
    /// Single owner-scoped ID so SwiftData treats it as one record.
    public var id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// "idle" | "work" | "breakPhase"
    public var phaseRaw: String = "idle"
    public var isRunning: Bool = false
    /// Wall-clock moment the running timer would complete. Nil when paused/idle.
    public var endTime: Date? = nil
    /// Remaining seconds when paused. Ignored when running.
    public var remainingSeconds: Double = 0
    public var totalSeconds: Double = 0
    public var label: String = ""
    public var breakKindsRaw: [String] = []
    /// Wall-clock moment the timer originally started (kept as session-start for save).
    public var startTime: Date? = nil
    public var updatedAt: Date = Date()
    /// Which device authored the most recent update — used to avoid feedback loops.
    public var deviceID: String = ""
    /// Monotonic Lamport-style counter. Each push does `version = max(local, remote) + 1`.
    /// Receivers ignore states with `version <= lastSeenVersion`, giving us a clear
    /// causal "this is newer" signal that doesn't depend on device clocks agreeing.
    /// Tiebreak on equal versions: larger deviceID wins (string comparison).
    public var version: Int = 0

    public init() {}

    public enum Phase: String, Sendable {
        case idle, work, breakPhase
    }

    public var phase: Phase {
        get { Phase(rawValue: phaseRaw) ?? .idle }
        set { phaseRaw = newValue.rawValue }
    }

    public var breakKinds: [BreakKind] {
        get { breakKindsRaw.compactMap { BreakKind(rawValue: $0) } }
        set { breakKindsRaw = newValue.map(\.rawValue) }
    }

    /// Remaining seconds, computed from anchor if running.
    public var liveRemaining: TimeInterval {
        if isRunning, let end = endTime {
            return max(0, end.timeIntervalSinceNow)
        }
        return max(0, remainingSeconds)
    }
}

// MARK: - Drill attempts

/// One recorded run at a specific problem in "Drill Mode" (the pacing
/// tracker built around the Stat-110-style 20-minute productive-struggle
/// framework). Each attempt logs: how long the user actively spent on it,
/// how many solution-line nudges they peeked, whether they pivoted to a
/// Monte Carlo sim, the outcome, and an optional confidence rating.
///
/// Why a separate entity (vs. extending StoredHomework): a single problem
/// can have multiple drill attempts over time (spaced repetition), and
/// the drill-specific signals (hints peeked, MC used, outcome) don't make
/// sense on the homework log. Keeping it separate also means the existing
/// homework/problem workflow is untouched.
@Model
public final class StoredDrillAttempt {
    public var id: UUID = UUID()
    /// Stable ID into `Stat110Catalog` (e.g. `stat110-hw2-hw-3`). Nil for
    /// freeform drills not tied to a catalog problem.
    public var catalogID: String? = nil
    /// Display title at drill-start time. Snapshot so renames in the
    /// catalog don't lose history.
    public var title: String = ""
    /// "Stat 110 HW2 Homework 3 — Three children…" etc.
    public var source: String = ""
    public var startTime: Date = Date()
    public var endTime: Date? = nil
    /// Active seconds (paused time excluded). The drill engine ticks this
    /// every 0.5s while not paused; persisted on stop.
    public var activeSeconds: Double = 0
    public var hintsPeeked: Int = 0
    public var monteCarloUsed: Bool = false
    /// "solved" | "stuck" | "skipped" — see DrillOutcome.
    public var outcomeRaw: String = DrillOutcome.stuck.rawValue
    /// 1-5, only meaningful when outcome=solved.
    public var confidence: Int = 0
    public var notes: String = ""

    public init() {}

    public var outcome: DrillOutcome {
        get { DrillOutcome(rawValue: outcomeRaw) ?? .stuck }
        set { outcomeRaw = newValue.rawValue }
    }
}

public enum DrillOutcome: String, Sendable, CaseIterable {
    /// Problem fully worked through under own power.
    case solved
    /// Walked through with AI assistance — got to the answer, but didn't
    /// own the derivation. Needs a cold solo redo on a scheduled date.
    case aiWalkthrough = "ai_walkthrough"
    /// Used hints / MC and still couldn't crack it. Defer for later.
    case stuck
    /// Bailed early without hints — usually means topic was wrong.
    case skipped

    public var displayName: String {
        switch self {
        case .solved:         return "Solved"
        case .aiWalkthrough:  return "AI walkthrough"
        case .stuck:          return "Stuck"
        case .skipped:        return "Skipped"
        }
    }
}

// MARK: - Mastery ladder
//
// New source of truth for what the user owns cold vs. what still needs
// review. Replaces the coarser confidence-based scheme on HomeworkProblem.
// Each catalog problem the user has touched has at most one MasteryRecord,
// plus a flat per-attempt audit log (StoredMasteryAttempt).
//
// The ladder is documented in the design proposal; in short:
//   familiarized  → R1 in 24h
//   r1Passed      → R2 in 2 or 3 days (per the "felt easy?" prompt)
//   r2Passed      → R3 in 7 days
//   retained      → no more reviews
//   lapsed        → failed a cold attempt; must re-familiarize before retry

public enum MasteryStage: String, Sendable, CaseIterable {
    /// Session 0 done (with or without AI). Next test is R1 in 24h.
    case familiarized
    /// R1 cold-passed. Next test is R2 in 2–3 days.
    case r1Passed
    /// R2 cold-passed. Next test is R3 in 7 days.
    case r2Passed
    /// R3 cold-passed. Drops out of the active review queue.
    case retained
    /// A cold attempt failed. Needs a fresh familiarization session
    /// before re-entering the ladder.
    case lapsed
}

public enum MasteryAttemptMode: String, Sendable {
    case familiarization
    case review
}

public enum MasteryAttemptOutcome: String, Sendable {
    /// Familiarization mode finished with AI assistance.
    case aiAssist
    /// Familiarization mode finished without AI.
    case soloFamiliarize
    /// Review mode — cold solve worked.
    case coldPass
    /// Review mode — couldn't get there cold.
    case coldFail
    /// User bailed without engaging.
    case skipped
}

@Model
public final class StoredMasteryRecord {
    /// Catalog ID is the natural primary key. SwiftData treats this as
    /// "stable identity for upsert" via our manual look-up — we don't
    /// declare it @Attribute(.unique) because that requires migration
    /// coordination and we already do explicit upserts in MasteryStore.
    public var catalogID: String = ""
    public var stageRaw: String = MasteryStage.familiarized.rawValue
    /// When the most recent attempt happened. nextDue is derived from
    /// (lastEvent, stage, r2IntervalDays).
    public var lastEvent: Date = Date()
    /// When the next review test should happen. Nil for `retained` and
    /// `lapsed` (lapsed records leave the queue until a fresh familiarization).
    public var nextDue: Date? = nil
    /// Captured at R1 pass. 2 if the user said "felt hard," 3 if "felt easy."
    public var r2IntervalDays: Int = 2
    /// Cached for the dashboard so we don't have to round-trip the catalog.
    public var problemTitle: String = ""
    public var sourceLabel: String = ""
    public var topic: String? = nil
    /// Set number for grouping in the dashboard (so we don't lean on title parsing).
    public var setNumber: Int = 0
    /// Running counters for at-a-glance stats; full log lives in StoredMasteryAttempt.
    public var familiarizationCount: Int = 0
    public var coldPassCount: Int = 0
    public var coldFailCount: Int = 0

    public init() {}

    public var stage: MasteryStage {
        get { MasteryStage(rawValue: stageRaw) ?? .familiarized }
        set { stageRaw = newValue.rawValue }
    }

    public var isDue: Bool {
        guard let due = nextDue else { return false }
        return due <= Date()
    }
}

@Model
public final class StoredMasteryAttempt {
    public var catalogID: String = ""
    public var date: Date = Date()
    public var modeRaw: String = MasteryAttemptMode.familiarization.rawValue
    public var outcomeRaw: String = MasteryAttemptOutcome.soloFamiliarize.rawValue
    public var durationSeconds: Double = 0
    public var notes: String = ""
    /// Only meaningful on R1 cold-pass attempts. Drives the R2 interval.
    public var feltEasy: Bool? = nil

    public init() {}

    public var mode: MasteryAttemptMode {
        get { MasteryAttemptMode(rawValue: modeRaw) ?? .familiarization }
        set { modeRaw = newValue.rawValue }
    }
    public var outcome: MasteryAttemptOutcome {
        get { MasteryAttemptOutcome(rawValue: outcomeRaw) ?? .soloFamiliarize }
        set { outcomeRaw = newValue.rawValue }
    }
}

/// One occurrence of a tracked health habit. `kind` is a `HealthKind`
/// raw value so new habits can be added without a schema change.
@Model
public final class StoredHealthEvent {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var kind: String = ""

    public init() {}

    public convenience init(id: UUID = UUID(), date: Date, kind: String) {
        self.init()
        self.id = id
        self.date = date
        self.kind = kind
    }
}

/// A "switch to X at time T" request from a device that may not hold the
/// live timer (e.g. a phone Shortcut run while the app is suspended).
/// Append-only so a stale sender can't clobber the shared timer state; each
/// device applies new commands to its own engine, splitting at `createdAt`.
@Model
public final class StoredTimerCommand {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var actionRaw: String = TimerCommand.Action.switchTo.rawValue
    public var label: String = ""
    public var minutes: Double = 0
    public var deviceID: String = ""

    public init() {}
}

// MARK: - Recall (retrieval practice)

/// A concept to reconstruct from memory: a prompt that doesn't give the
/// answer away, plus a reference answer to check against. Scheduled by
/// `RecallScheduler`.
@Model
public final class StoredKnowledgeItem {
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    /// Focus category it belongs to ("Quant", "SWE", a class name…).
    public var course: String = ""
    public var topic: String = ""
    public var prompt: String = ""
    public var answer: String = ""
    public var kindRaw: String = KnowledgeKind.concept.rawValue
    /// Where the reference answer comes from (lecture, textbook section…).
    public var source: String = ""
    /// Reference answer was drafted by Claude and not yet checked by the user.
    public var answerByAI: Bool = false
    public var intervalDays: Double = 0
    public var nextDue: Date = Date()
    public var reps: Int = 0
    public var lapses: Int = 0
    public var archived: Bool = false
    /// The recall note it was made from, if any.
    public var noteID: UUID? = nil

    public init() {}

    public var kind: KnowledgeKind {
        get { KnowledgeKind(rawValue: kindRaw) ?? .concept }
        set { kindRaw = newValue.rawValue }
    }
}

/// One retrieval attempt. `response` is what the user produced before
/// seeing the answer; it's never overwritten by hints or feedback.
@Model
public final class StoredRecallAttempt {
    public var id: UUID = UUID()
    public var itemID: UUID = UUID()
    public var date: Date = Date()
    public var response: String = ""
    public var score: Int = 0
    public var hinted: Bool = false
    /// Days since the item was last reviewed (or created) — the real delay
    /// the retrieval spanned, used for retention-by-delay stats.
    public var delayDays: Double = 0
    /// Claude's suggested score, -1 when not asked.
    public var aiScore: Int = -1
    public var aiFeedback: String = ""
    public var secondsToAnswer: Double = 0

    public init() {}

    public var grade: RecallGrade { RecallGrade(rawValue: score) ?? .forgot }
    /// Correct and produced without any cue — the only kind that counts as retrieval success.
    public var isUnaidedSuccess: Bool { score >= RecallGrade.got.rawValue && !hinted }
}

/// Free recall written from memory: right after a focus block ("session"),
/// or the next morning about the previous day ("yesterday").
@Model
public final class StoredRecallNote {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var kindRaw: String = RecallNoteKind.session.rawValue
    public var text: String = ""
    public var label: String = ""
    public var sessionStart: Date? = nil
    public var sessionMinutes: Double = 0
    public var aiFeedback: String = ""

    public init() {}

    public var kind: RecallNoteKind {
        get { RecallNoteKind(rawValue: kindRaw) ?? .session }
        set { kindRaw = newValue.rawValue }
    }
}

// MARK: - Schema

public enum FocusSchema {
    public static let allModels: [any PersistentModel.Type] = [
        StoredWorkSession.self,
        StoredProblem.self,
        StoredHomework.self,
        StoredDayRecord.self,
        StoredScratchItem.self,
        StoredTimerState.self,
        StoredDrillAttempt.self,
        StoredMasteryRecord.self,
        StoredMasteryAttempt.self,
        StoredHealthEvent.self,
        StoredTimerCommand.self,
        StoredKnowledgeItem.self,
        StoredRecallAttempt.self,
        StoredRecallNote.self,
    ]
}
