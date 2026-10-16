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
}
