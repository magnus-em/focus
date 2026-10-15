import Foundation

public enum ScreenJournalReader {
    public static func find(id: UUID, day: Date, directory: URL) throws -> (row: ScreenJournal.Row, text: String)? {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let prefix = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "jsonl" }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for file in files {
            var bases: [String: (row: ScreenJournal.Row, text: String)] = [:]
            for data in try Data(contentsOf: file).split(separator: 10) {
                guard let row = try? decoder.decode(ScreenJournal.Row.self, from: Data(data)) else { continue }
                guard let text = ScreenJournal.reconstruct(row, base: bases[row.windowKey]) else {
                    bases[row.windowKey] = nil; continue
                }
                bases[row.windowKey] = (row, text)
                if row.id == id { return (row, text) }
            }
        }
        return nil
    }
}
