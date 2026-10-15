import XCTest
@testable import FocusCore

final class ScreenTextLayoutTests: XCTestCase {
    func testTwoColumnsAreReadAsColumnsBelowFullWidthHeading() {
        var lines = [ScreenTextLayout.Line(text: "Heading", minX:0.1,maxX:0.9,minY:0.9,maxY:0.95)]
        for i in 0..<4 {
            let y = 0.8 - Double(i) * 0.15
            lines += [.init(text:"L\(i)",minX:0.1,maxX:0.44,minY:y,maxY:y+0.02),
                      .init(text:"R\(i)",minX:0.56,maxX:0.9,minY:y,maxY:y+0.02)]
        }
        XCTAssertEqual(ScreenTextLayout.ordered(lines), ["Heading","L0","L1","L2","L3","R0","R1","R2","R3"])
    }
    func testSingleColumnAndEmptyInputPreserveEveryLine() {
        XCTAssertEqual(ScreenTextLayout.ordered([]), [])
        let lines = [ScreenTextLayout.Line(text:"second",minX:0.1,maxX:0.9,minY:0.4,maxY:0.5),
                     .init(text:"first",minX:0.1,maxX:0.9,minY:0.7,maxY:0.8)]
        XCTAssertEqual(ScreenTextLayout.ordered(lines), ["first","second"])
    }
}
