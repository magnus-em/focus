import Foundation
import SwiftData
import AppKit
import FocusCore

/// Mac equivalent of the iPad's DataExport. Same snapshot format —
/// dump every Stored* model to one timestamped JSON file, then offer
/// it via the system save panel.
enum DataExport {
    struct Snapshot: Codable {
        struct WorkSessionDTO: Codable {
            let id: UUID
            let startTime: Date
            let durationMinutes: Double
            let type: String
            let label: String?
            let breakKinds: [String]
        }
        struct ProblemDTO: Codable {
            let id: UUID
            let date: Date
            let title: String
            let domain: String
            let categories: [String]
            let difficulty: String
            let confidence: String
            let needsReview: Bool
            let source: String
            let notes: String
            let url: String
            let solveMinutes: Int?
        }
        struct HomeworkDTO: Codable {
            let id: UUID
            let date: Date
            let title: String
            let source: String
            let difficulty: String
            let confidence: String
            let usedAI: Bool
            let notes: String
            let url: String
        }
        struct DayRecordDTO: Codable {
            let id: UUID
            let calendarDay: Date
            let dayStart: Date?
            let dayEnd: Date?
        }
        struct ScratchDTO: Codable {
            let id: UUID
            let text: String
            let isChecked: Bool
            let order: Int
        }

        let exportedAt: Date
        let sessions: [WorkSessionDTO]
        let problems: [ProblemDTO]
        let homework: [HomeworkDTO]
        let dayRecords: [DayRecordDTO]
        let scratch: [ScratchDTO]
        let recallCards: [RecallCardDTO]
        let recallAttempts: [RecallAttemptDTO]
        let recallNotes: [RecallNoteDTO]
    }

    struct RecallCardDTO: Codable {
        let id: UUID; let createdAt: Date; let course: String; let topic: String
        let kind: String; let prompt: String; let answer: String; let source: String
        let answerByAI: Bool; let intervalDays: Double; let nextDue: Date
        let reps: Int; let lapses: Int; let archived: Bool
    }

    struct RecallAttemptDTO: Codable {
        let id: UUID; let itemID: UUID; let date: Date; let response: String
        let score: Int; let hinted: Bool; let delayDays: Double
        let aiScore: Int; let aiFeedback: String; let secondsToAnswer: Double
    }

    struct RecallNoteDTO: Codable {
        let id: UUID; let date: Date; let kind: String; let text: String
        let label: String; let sessionStart: Date?; let sessionMinutes: Double; let aiFeedback: String
    }

    static func showSavePanel(container: ModelContainer) {
        let ctx = ModelContext(container)
        let sessions = (try? ctx.fetch(FetchDescriptor<StoredWorkSession>())) ?? []
        let problems = (try? ctx.fetch(FetchDescriptor<StoredProblem>())) ?? []
        let homework = (try? ctx.fetch(FetchDescriptor<StoredHomework>())) ?? []
        let days = (try? ctx.fetch(FetchDescriptor<StoredDayRecord>())) ?? []
        let scratch = (try? ctx.fetch(FetchDescriptor<StoredScratchItem>())) ?? []
        let cards = (try? ctx.fetch(FetchDescriptor<StoredKnowledgeItem>())) ?? []
        let recallAttempts = (try? ctx.fetch(FetchDescriptor<StoredRecallAttempt>())) ?? []
        let recallNotes = (try? ctx.fetch(FetchDescriptor<StoredRecallNote>())) ?? []

        let snap = Snapshot(
            exportedAt: Date(),
            sessions: sessions.map {
                .init(id: $0.id, startTime: $0.startTime,
                      durationMinutes: $0.durationMinutes, type: $0.typeRaw,
                      label: $0.label, breakKinds: $0.breakKindsRaw)
            },
            problems: problems.map {
                .init(id: $0.id, date: $0.date, title: $0.title,
                      domain: $0.domainRaw, categories: $0.categories,
                      difficulty: $0.difficultyRaw, confidence: $0.confidenceRaw,
                      needsReview: $0.needsReview, source: $0.source,
                      notes: $0.notes, url: $0.urlString,
                      solveMinutes: $0.solveMinutes)
            },
            homework: homework.map {
                .init(id: $0.id, date: $0.date, title: $0.title,
                      source: $0.source, difficulty: $0.difficultyRaw,
                      confidence: $0.confidenceRaw, usedAI: $0.usedAI,
                      notes: $0.notes, url: $0.urlString)
            },
            dayRecords: days.map {
                .init(id: $0.id, calendarDay: $0.calendarDay,
                      dayStart: $0.dayStart, dayEnd: $0.dayEnd)
            },
            scratch: scratch.map {
                .init(id: $0.id, text: $0.text,
                      isChecked: $0.isChecked, order: $0.order)
            },
            recallCards: cards.map {
                .init(id: $0.id, createdAt: $0.createdAt, course: $0.course, topic: $0.topic,
                      kind: $0.kindRaw, prompt: $0.prompt, answer: $0.answer, source: $0.source,
                      answerByAI: $0.answerByAI, intervalDays: $0.intervalDays, nextDue: $0.nextDue,
                      reps: $0.reps, lapses: $0.lapses, archived: $0.archived)
            },
            recallAttempts: recallAttempts.map {
                .init(id: $0.id, itemID: $0.itemID, date: $0.date, response: $0.response,
                      score: $0.score, hinted: $0.hinted, delayDays: $0.delayDays,
                      aiScore: $0.aiScore, aiFeedback: $0.aiFeedback, secondsToAnswer: $0.secondsToAnswer)
            },
            recallNotes: recallNotes.map {
                .init(id: $0.id, date: $0.date, kind: $0.kindRaw, text: $0.text, label: $0.label,
                      sessionStart: $0.sessionStart, sessionMinutes: $0.sessionMinutes, aiFeedback: $0.aiFeedback)
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snap) else { return }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "focus-export-\(f.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
