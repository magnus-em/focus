import Foundation
import Darwin

@main struct LocalClassifierCheck {
    static func main() async {
        guard #available(macOS 26.0, *) else { print("unsupported OS"); exit(2) }
        guard ScreenLabeler.modelAvailable else { print("on-device model unavailable"); exit(2) }
        let cases: [(String, String, String, String, String?)] = [
            ("Focus model integration", "ChatGPT", "Install project on iPhone and iPad", "Improve the Focus app dashboard and screen tracking. Use Apple's FoundationModels to classify visible activity. AI means learning machine learning or neural networks, not using an assistant. Keep the app local.", "Admin"),
            ("ML study", "ChatGPT", "Learn backpropagation", "Explain backpropagation in a neural network. Derive how the chain rule computes the gradient of the loss function. I am studying deep learning and want to understand gradient descent.", "AI"),
            ("Math proof", "ChatGPT", "MATH 244 induction proof", "My discrete math assignment asks me to prove by induction that the sum of the first n odd integers is n squared. Give me a hint for the induction step, without writing the entire proof.", "Math"),
            ("C pointers", "Claude", "CPSC 3231 pointers", "I am preparing for my computer systems midterm. Explain why dereferencing a freed pointer causes undefined behavior in C, and how malloc and free affect memory ownership.", "SWE"),
            ("Personal curiosity", "ChatGPT", "Why do sauna hats help?", "What is the purpose of a sauna hat? Explain how wool insulation reduces heating of the head in hot air. I am curious about the material science.", nil),
            ("Ambiguous generic chat", "ChatGPT", "ChatGPT", "New chat. What should we work on? Type a message.", "Math")
        ]
        let expectations: [String: (String?, Bool)] = ["Focus model integration": ("SWE", false), "ML study": ("AI", false),
                                                       "Math proof": ("Math", false), "C pointers": ("SWE", false),
                                                       "Personal curiosity": ("Reading", false), "Ambiguous generic chat": (nil, true)]
        var failures = 0
        for (name, app, title, text, current) in cases {
            let start = Date()
            let result = await ScreenLabeler.classifyDetailed(app: app, title: title, text: text,
                categories: ["AI", "Math", "SWE", "Admin", "Reading", "Leisure", "Quant", "HW"], current: current)
            let seconds = Date().timeIntervalSince(start)
            if let result {
                let expected = expectations[name]!
                let passed = result.category == expected.0 && result.uncertain == expected.1
                if !passed { failures += 1 }
                let payload: [String: Any] = ["case": name, "category": result.category ?? "Unclear", "uncertain": result.uncertain,
                                            "reason": result.reason, "summary": result.summary, "seconds": seconds, "passed": passed,
                                            "expectedCategory": expected.0 ?? "Unclear", "expectedUncertain": expected.1]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) {
                    print(json)
                }
            } else { failures += 1; print("\(name): failed, \(seconds)s, \(ScreenLabeler.lastError ?? "no error reported")") }
            fflush(stdout)
        }
        print("\(cases.count - failures)/\(cases.count) synthetic classification checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
