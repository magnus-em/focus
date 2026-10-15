import Foundation

public enum ScreenTextLayout {
    public struct Line: Sendable {
        public let text: String
        public let minX: Double, maxX: Double, minY: Double, maxY: Double
        public init(text: String, minX: Double, maxX: Double, minY: Double, maxY: Double) {
            self.text = text; self.minX = minX; self.maxX = maxX; self.minY = minY; self.maxY = maxY
        }
        fileprivate var y: Double { (minY + maxY) / 2 }
    }
    public static func ordered(_ input: [Line]) -> [String] {
        let lines = input.filter { !$0.text.isEmpty }
        func topDown(_ lines: [Line]) -> [Line] { lines.sorted { $0.y == $1.y ? $0.minX < $1.minX : $0.y > $1.y } }
        var choice: (left: [Line], right: [Line], crossing: [Line], score: Double)?
        for cut in [0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65] {
            let left = lines.filter { $0.maxX <= cut - 0.01 }, right = lines.filter { $0.minX >= cut + 0.01 }
            let crossing = lines.filter { !($0.maxX <= cut - 0.01 || $0.minX >= cut + 0.01) }
            guard left.count >= 3, right.count >= 3, crossing.count <= max(2, lines.count / 5),
                  min(left.map(\.maxY).max()!, right.map(\.maxY).max()!) - max(left.map(\.minY).min()!, right.map(\.minY).min()!) >= 0.15 else { continue }
            let score = Double(left.count + right.count) - Double(abs(left.count - right.count)) * 0.1 - abs(0.5 - cut)
            if choice == nil || score > choice!.score { choice = (left, right, crossing, score) }
        }
        guard let choice else { return topDown(lines).map(\.text) }
        var left = choice.left, right = choice.right, output: [Line] = []
        for barrier in topDown(choice.crossing) {
            output += topDown(left.filter { $0.y > barrier.y }) + topDown(right.filter { $0.y > barrier.y })
            output.append(barrier)
            left.removeAll { $0.y > barrier.y }; right.removeAll { $0.y > barrier.y }
        }
        output += topDown(left) + topDown(right)
        return output.map(\.text)
    }
}
