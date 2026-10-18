import XCTest
import SwiftData
@testable import FocusCore

final class LogEditTests: XCTestCase {
    private func context() throws -> ModelContext {
        let config = ModelConfiguration(schema: Schema(FocusSchema.allModels), isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: Schema(FocusSchema.allModels), configurations: [config]))
    }
    private let t0 = Date(timeIntervalSince1970: 1_792_150_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private func add(_ c: ModelContext, _ start: Double, _ minutes: Double, _ label: String?) {
        c.insert(StoredWorkSession(value: WorkSession(startTime: at(start), durationMinutes: minutes,
                                                      type: label == nil ? .shortBreak : .work, label: label)))
    }
    private func log(_ c: ModelContext) throws -> [String] {
        try c.fetch(FetchDescriptor<StoredWorkSession>(sortBy: [SortDescriptor(\.startTime)])).map {
            "\(Int(($0.startTime.timeIntervalSince(t0) / 60).rounded()))+\(Int($0.durationMinutes.rounded())) \($0.label ?? "Break")"
        }
    }

    func testPaintSplitsAroundAndUndoRestores() throws {
        let c = try context()
        add(c, 0, 120, "Math")
        try c.save()
        let undo = try XCTUnwrap(LogEdit.paint(start: at(30), end: at(60), label: "Meals", in: c))
        XCTAssertEqual(try log(c), ["0+30 Math", "30+30 Meals", "60+60 Math"])
        XCTAssertTrue(LogEdit.undo(undo, in: c))
        XCTAssertEqual(try log(c), ["0+120 Math"])
    }

    func testPaintFillsAGapAndRefusesUnsavedWork() throws {
        let c = try context()
        add(c, 0, 10, "Math")
        add(c, 40, 10, "SWE")
        try c.save()
        XCTAssertNotNil(LogEdit.paint(start: at(10), end: at(40), label: nil, in: c))
        XCTAssertEqual(try log(c), ["0+10 Math", "10+30 Break", "40+10 SWE"])
        add(c, 60, 5, "AI")
        XCTAssertNil(LogEdit.paint(start: at(60), end: at(70), label: "HW", in: c))
    }

    func testDeleteLeavesAGapAndUndoRefusesAfterAnotherEdit() throws {
        let c = try context()
        add(c, 0, 30, "Leisure")
        add(c, 30, 30, "Math")
        try c.save()
        let id = try XCTUnwrap(c.fetch(FetchDescriptor<StoredWorkSession>()).first { $0.label == "Leisure" }?.id)
        let undo = try XCTUnwrap(LogEdit.delete(id: id, in: c))
        XCTAssertEqual(try log(c), ["30+30 Math"])
        XCTAssertNotNil(LogEdit.paint(start: at(0), end: at(30), label: "Sleep", in: c))
        XCTAssertFalse(LogEdit.undo(undo, in: c))
    }

    func testClearLeavesAGap() throws {
        let c = try context()
        add(c, 0, 60, "Math")
        try c.save()
        XCTAssertNotNil(LogEdit.paint(start: at(20), end: at(40), label: nil, fill: false, in: c))
        XCTAssertEqual(try log(c), ["0+20 Math", "40+20 Math"])
    }

    /// 10/14's shape: a device's Class ran on over the blocks logged after it,
    /// and a second Class row covered the real class.
    func testAutoResolveKeepsTheLaterSwitchesAndMergesDuplicates() throws {
        let c = try context()
        add(c, 0, 300, "Class")
        add(c, 25, 18, "Leisure")
        add(c, 43, 40, "Class")
        add(c, 83, 90, "Leisure")
        add(c, 173, 60, "Admin")
        add(c, 233, 30, nil)
        try c.save()
        for _ in 0..<50 {
            let rows = try c.fetch(FetchDescriptor<StoredWorkSession>()).map(\.asValue)
            guard let o = TimeIntegrity.overlaps(in: rows, from: at(-60), to: at(400)).first else { break }
            XCTAssertNotNil(LogEdit.fixOverlap(o, keep: TimeIntegrity.autoKeep(o), in: c))
        }
        XCTAssertEqual(try log(c), ["0+25 Class", "25+18 Leisure", "43+40 Class", "83+90 Leisure",
                                    "173+60 Admin", "233+30 Break", "263+37 Class"])
    }

    func testOverlapKeepOne() throws {
        let c = try context()
        add(c, 0, 60, "Math")
        add(c, 30, 60, "Reading")
        try c.save()
        let rows = try c.fetch(FetchDescriptor<StoredWorkSession>(sortBy: [SortDescriptor(\.startTime)])).map(\.asValue)
        let overlap = try XCTUnwrap(TimeIntegrity.overlaps(in: rows, from: at(-60), to: at(120)).first)
        XCTAssertNotNil(LogEdit.fixOverlap(overlap, keep: rows[1].id, in: c))
        XCTAssertEqual(try log(c), ["0+30 Math", "30+60 Reading"])
    }

    /// 10/18: Meals 10:03:42 had synced in ending 5:50 AM the next day. The
    /// Mac's own Meals save (14 s later, so not a dedup) merged into it, then
    /// cutting it for Math left a future tail. Now the future row is cut at
    /// now first, and merges and cuts never reach past now.
    func testFutureRowNeverFeedsAMergeOrATail() throws {
        let c = try context()
        let now = at(63)
        add(c, -634, 634, "Sleep")
        add(c, 0, 1187, "Meals")
        try c.save()
        XCTAssertEqual(LogEdit.clampFuture(now: now, runningSince: nil, in: c).count, 1)
        XCTAssertEqual(try log(c), ["-634+634 Sleep", "0+63 Meals"])
        add(c, 0.25, 62.75, "Meals")
        try c.save()
        var rows = try c.fetch(FetchDescriptor<StoredWorkSession>()).map(\.asValue)
        let dup = try XCTUnwrap(TimeIntegrity.overlaps(in: rows, from: at(-700), to: now).first)
        XCTAssertNil(TimeIntegrity.autoKeep(dup))
        XCTAssertNotNil(LogEdit.fixOverlap(dup, keep: nil, now: now, in: c))
        XCTAssertEqual(try log(c), ["-634+634 Sleep", "0+63 Meals"])
        add(c, 63, 2, "Math")
        try c.save()
        rows = try c.fetch(FetchDescriptor<StoredWorkSession>()).map(\.asValue)
        XCTAssertTrue(TimeIntegrity.overlaps(in: rows, from: at(-700), to: at(65)).isEmpty)
    }

    func testMergeAndCutStopAtNowEvenWithoutAClamp() throws {
        let c = try context()
        add(c, 0, 60, "Meals")
        add(c, 30, 1200, "Meals")
        try c.save()
        var rows = try c.fetch(FetchDescriptor<StoredWorkSession>(sortBy: [SortDescriptor(\.startTime)])).map(\.asValue)
        let o = try XCTUnwrap(TimeIntegrity.overlaps(in: rows, from: at(-60), to: at(90)).first)
        XCTAssertNotNil(LogEdit.fixOverlap(o, keep: nil, now: at(90), in: c))
        XCTAssertEqual(try log(c), ["0+90 Meals"])

        add(c, 100, 1200, "Meals")
        add(c, 110, 5, "Math")
        try c.save()
        rows = try c.fetch(FetchDescriptor<StoredWorkSession>(sortBy: [SortDescriptor(\.startTime)])).map(\.asValue)
        let cut = try XCTUnwrap(TimeIntegrity.overlaps(in: rows, from: at(95), to: at(120)).first)
        XCTAssertEqual(TimeIntegrity.autoKeep(cut), cut.second.id)
        XCTAssertNotNil(LogEdit.fixOverlap(cut, keep: cut.second.id, now: at(120), in: c))
        XCTAssertEqual(try log(c), ["0+90 Meals", "100+10 Meals", "110+5 Math", "115+5 Meals"])
    }

    func testClampCutsAtWhatIsRunningAndLeavesPastRowsAlone() throws {
        let c = try context()
        add(c, 0, 30, "Math")
        add(c, 30, 900, "Leisure")
        try c.save()
        XCTAssertEqual(LogEdit.clampFuture(now: at(100), runningSince: at(70), in: c).count, 1)
        XCTAssertEqual(try log(c), ["0+30 Math", "30+40 Leisure"])
        XCTAssertTrue(LogEdit.clampFuture(now: at(100), runningSince: at(70), in: c).isEmpty)
    }

    func testAutoResolveWaitsForTheLogToSettle() {
        XCTAssertEqual(TimeIntegrity.autoResolveWait(lastChange: at(0), now: at(0))!, TimeIntegrity.settleSeconds, accuracy: 0.001)
        XCTAssertNotNil(TimeIntegrity.autoResolveWait(lastChange: at(0), now: at(0.4)))
        XCTAssertNil(TimeIntegrity.autoResolveWait(lastChange: at(0), now: at(0.5)))
    }
}
