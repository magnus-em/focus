import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// On-device Apple Intelligence labeling shared by the Mac screen watcher and
/// the iPad screen broadcast: one category + summary per snapshot, and study
/// notes per block of work.
@available(macOS 26.0, iOS 26.0, *)
public enum ScreenLabeler {
    public static var modelAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Tuned against the 3B on-device model: without these it calls a discrete
    /// math problem set "Reading".
    public static let hints: [String: String] = [
        "Math": "mathematics work, right now mostly discrete math: logic, sets, functions, relations, proofs by induction or contradiction, counting, combinatorics, graphs, math problem sets and lectures (math notation only; never programming, C, assembly, memory or operating systems)",
        "HW": "homework for non-math classes: essays, assigned readings, econ or history problem sets",
        "SWE": "programming: LeetCode, NeetCode, algorithm practice, and writing, reading or compiling code in any language (C, assembly, Python), Compiler Explorer, debugging, asking an AI chat about code, building their own apps (like the Focus app) with Claude, Claude Code or Codex, and studying CS systems courses (C, assembly, memory layout, processes, compilers), midterms included",
        "Quant": "quant interview prep: probability puzzles, brainteasers, mental math, QuantGuide",
        "AI": "AI/ML work: machine learning models, training, datasets, neural networks, ML papers (using an AI chat or coding assistant is not AI by itself)",
        "Reading": "reading books or articles, or exploring ideas with an AI chat, for personal curiosity, not for a class",
        "Leisure": "entertainment: YouTube, streaming, games, social feeds",
        "Admin": "email, forms, calendars, settings, errands online",
    ]

    /// Plain-text output: with a schema the 3B model lists bare terms
    /// ("Euler tour") instead of statements you could review from.
    public static func studyNotes(category: String, windows: [String], previous: (String, [String])?,
                           pages: [(window: String, text: String)]) async -> (String, [String])? {
        var budget = 2400
        var chunks: [String] = []
        for p in pages.reversed() where budget > 200 {
            let t = String(p.text.prefix(min(900, budget)))
            budget -= t.count
            chunks.insert("--- \(p.window)\n\(t)", at: 0)
        }
        let prev = previous.map { "\($0.0)\n" + $0.1.map { "- \($0)" }.joined(separator: "\n") } ?? "(none)"
        let prompt = """
        Category: \(category)
        Windows: \(windows.joined(separator: "; "))
        Earlier notes for this block:
        \(prev)
        New screen text:
        \(chunks.joined(separator: "\n"))
        """
        let session = LanguageModelSession(instructions: """
        You keep a study log for a student. From the text that was on their screen, write study notes: what they learned or worked on, as the student would jot it down to review later.
        Format: first line is a title under 8 words. Then 2 to 6 lines starting with "- ", each a complete sentence explaining one idea, result, problem or step, under 25 words.
        Update the notes so far with the new text: keep what still holds, add what's new, drop repeats. If the screen is entertainment or admin, say plainly what was watched or done.
        Use only facts in the input. Never invent. Never just list terms.
        """)
        guard let r = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0)) else { return nil }
        let lines = r.content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let bulletMarks: [String] = ["- ", "• ", "* "]
        // It sometimes doubles the marker ("- - …").
        func strip(_ l: String) -> String? {
            guard let m = bulletMarks.first(where: { l.hasPrefix($0) }) else { return nil }
            let rest = String(l.dropFirst(m.count)).trimmingCharacters(in: .whitespaces)
            return strip(rest) ?? rest
        }
        let bullets = lines.compactMap(strip).filter { $0.count > 3 }
        // It sometimes copies the prompt's labels as the title ("Notes so far").
        var title = lines.first { l in !bulletMarks.contains { l.hasPrefix($0) } }?
            .trimmingCharacters(in: .init(charactersIn: "#*:\" ")) ?? ""
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if ["notes so far", "earlier notes", "earlier notes for this block", "study notes", "notes"].contains(title.lowercased()) {
            title = previous?.0 ?? ""
        }
        guard !title.isEmpty || !bullets.isEmpty else { return nil }
        return (String((title.isEmpty ? windows.first ?? category : title).prefix(80)), Array(bullets.prefix(6)))
    }

    /// `current`: what the student says they're doing. The 3B model calls any
    /// page of numbers Math (two's complement during C/systems review), so it
    /// keeps the student's own label unless the screen clearly shows other work.
    public static func classify(app: String, title: String, text: String, categories: [String],
                                current: String? = nil) async -> (String?, String)? {
        let lines = categories.map { c in hints[c].map { "- \(c): \($0)" } ?? "- \(c)" }
        let instructions = """
        You label what a student is doing on their computer or tablet from the app, window title and on-screen text. Pick the single best category.
        \(lines.joined(separator: "\n"))
        - Unclear: not enough information.
        Coursework and problem sets are never Reading.
        A course code in the window title names the subject: MATH courses are Math, CPSC courses are SWE.
        \(current.map { categories.contains($0) ? "The student says they are doing \($0) right now. Answer \($0) unless the screen clearly shows a different kind of work; numbers, binary or arithmetic inside programming material are still \($0)." : "" } ?? "")
        """
        do {
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Guess", properties: [
                .init(name: "summary", description: "What is on this screen, under 12 words, using names and topics visible in the text. Don't repeat the category descriptions.",
                      schema: DynamicGenerationSchema(type: String.self)),
                .init(name: "category", schema: DynamicGenerationSchema(name: "Category", anyOf: categories + ["Unclear"])),
            ]), dependencies: [])
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: "App: \(app)\nWindow: \(title)\nScreen text: \(text)",
                                              schema: schema, options: GenerationOptions(temperature: 0))
            let category = try r.content.value(String.self, forProperty: "category")
            let summary = try r.content.value(String.self, forProperty: "summary")
            return (categories.contains(category) ? category : nil, summary)
        } catch {
            return nil
        }
    }
}

#endif
