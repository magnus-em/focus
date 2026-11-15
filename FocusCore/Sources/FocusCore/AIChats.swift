import Foundation
import CryptoKit

/// What you asked AI tools, word for word: read from the ChatGPT/Claude
/// desktop windows (accessibility), the Claude Code and Codex transcripts on
/// disk, and ChatGPT/Claude data exports. Only your own messages are kept,
/// never the answers.
public enum AIChats {
    public enum Source: String, Codable, Sendable { case window, transcript, export }

    public struct Message: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var at: Date
        public var tool: String
        public var conversation: String?
        public var text: String
        public var source: Source
        /// Already in the conversation when first seen, so `at` is when it was
        /// seen, not when it was sent.
        public var backfill: Bool
        public var project: String?

        public init(id: String, at: Date, tool: String, conversation: String?, text: String, source: Source,
                    backfill: Bool = false, project: String? = nil) {
            self.id = id; self.at = at; self.tool = tool; self.conversation = conversation; self.text = text
            self.source = source; self.backfill = backfill; self.project = project
        }

        public var textKey: String { AIChats.hash(tool + "|" + AIChats.normalized(text)) }
    }

    public static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Desktop chat windows

    /// What one read of a chat window showed: its title and your messages, in
    /// order, with the words of the reply under each (Claude app chats only;
    /// empty when replies weren't read).
    public struct WindowRead: Equatable, Sendable {
        public var tool: String
        public var title: String
        public var messages: [String]
        public var replies: [Int]
        public var at: Date
        public init(tool: String, title: String, messages: [String], replies: [Int] = [], at: Date) {
            self.tool = tool; self.title = title; self.messages = messages; self.replies = replies; self.at = at
        }
        public var conversationKey: String { AIChats.hash(tool + "|" + (messages.first.map(AIChats.normalized) ?? title)) }
    }

    static let genericTitles: Set<String> = ["chatgpt", "new chat", "claude", "", "gemini"]

    /// Messages in `current` not recorded before. A message that appears at
    /// the end of the conversation you were just looking at was sent now; ones
    /// already there when a conversation opens are kept as backfill (once per
    /// wording, so reopening an old chat adds nothing).
    public static func newMessages(previous: WindowRead?, current: WindowRead, seenIDs: Set<String>,
                                   seenText: Set<String>) -> [Message] {
        let sameConversation: Bool = {
            guard let p = previous, p.tool == current.tool, current.at.timeIntervalSince(p.at) <= 30 else { return false }
            if p.conversationKey == current.conversationKey { return true }
            let pt = p.title.lowercased(), ct = current.title.lowercased()
            return pt == ct || p.messages.isEmpty || genericTitles.contains(pt)
        }()
        let previousCount = previous?.messages.count ?? 0
        var out: [Message] = []
        for (i, (m, id)) in zip(current.messages, messageIDs(current)).enumerated() {
            guard let id, !seenIDs.contains(id) else { continue }
            let live = sameConversation && i >= previousCount - 1
            let textKey = hash(current.tool + "|" + normalized(m))
            if !live && seenText.contains(textKey) { continue }
            out.append(Message(id: id, at: current.at, tool: current.tool,
                               conversation: genericTitles.contains(current.title.lowercased()) ? nil : current.title,
                               text: m, source: .window, backfill: !live))
        }
        return out
    }

    /// The id each of a read's messages is recorded under (nil for blank ones).
    public static func messageIDs(_ read: WindowRead) -> [String?] {
        let conv = read.conversationKey
        var counts: [String: Int] = [:]
        return read.messages.map { m in
            let n = normalized(m)
            guard !n.isEmpty else { return nil }
            counts[n, default: 0] += 1
            return hash("\(read.tool)|\(conv)|\(n)|\(counts[n]!)")
        }
    }

    /// Replies that grew past what's been counted, as (message id, words now,
    /// words added). Only replies to messages you sent while Focus watched
    /// (`live`) count, so opening an old chat adds nothing, and a reply still
    /// being written counts as it grows.
    public static func replyGrowth(_ read: WindowRead, live: Set<String>,
                                   counted: [String: Int]) -> [(id: String, words: Int, added: Int)] {
        guard read.replies.count == read.messages.count else { return [] }
        return zip(messageIDs(read), read.replies).compactMap { id, w in
            guard let id, live.contains(id), w > counted[id] ?? 0 else { return nil }
            return (id, w, w - (counted[id] ?? 0))
        }
    }

    // MARK: - Agent transcripts

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    /// One line of a Claude Code transcript (`~/.claude/projects/*/*.jsonl`):
    /// a prompt you typed, or nil for tool results, injected context,
    /// scheduled runs and slash-command plumbing.
    public static func claudeCodePrompt(_ line: Data) -> Message? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              o["type"] as? String == "user", o["isMeta"] as? Bool != true, o["isSidechain"] as? Bool != true,
              o["promptSource"] as? String != "system", o["isCompactSummary"] as? Bool != true,
              o["isVisibleInTranscriptOnly"] as? Bool != true,
              let msg = o["message"] as? [String: Any], let at = date(o["timestamp"] as? String) else { return nil }
        var text = ""
        if let s = msg["content"] as? String { text = s }
        else if let blocks = msg["content"] as? [[String: Any]] {
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("[Request interrupted"), !isCompactSummary(text) else { return nil }
        let cwd = o["cwd"] as? String
        let id = (o["uuid"] as? String) ?? hash(text + "\(at.timeIntervalSince1970)")
        return Message(id: "cc-" + id, at: at, tool: "Claude Code", conversation: o["sessionId"] as? String,
                       text: text, source: .transcript,
                       project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent })
    }

    /// Claude Code's summary when it compacts a long conversation, logged as
    /// a "user" message (~2,000 words each; 15 were saved as yours by 11/14).
    public static func isCompactSummary(_ text: String) -> Bool {
        text.hasPrefix("This session is being continued from a previous conversation")
    }

    /// One line of a Codex session (`~/.codex/sessions/**/*.jsonl`). Codex
    /// also logs its environment, AGENTS.md and mail from Claude as "user";
    /// those are skipped. `cwd` comes from the file's session_meta line.
    public static func codexPrompt(_ line: Data, cwd: String?) -> Message? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              o["type"] as? String == "response_item", let p = o["payload"] as? [String: Any],
              p["type"] as? String == "message", p["role"] as? String == "user",
              let at = date(o["timestamp"] as? String) else { return nil }
        let parts = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        guard let text = codexText(parts.joined(separator: "\n")) else { return nil }
        return Message(id: "cx-" + hash("\(at.timeIntervalSince1970)|\(text)"), at: at, tool: "Codex",
                       conversation: nil, text: text, source: .transcript,
                       project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent })
    }

    /// What you typed in a Codex turn, or nil for what Codex adds itself:
    /// environment and AGENTS.md context, IDE wrappers without a request,
    /// its approval reviewer ("The following is the Codex agent history…")
    /// and mail from Claude.
    public static func codexText(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = text.range(of: #"## My request for Codex:?"#, options: .regularExpression) {
            text = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if text.hasPrefix("#") && (text.contains("AGENTS.md") || text.hasPrefix("# Files mentioned")
                                          || text.hasPrefix("# Files pasted") || text.hasPrefix("# Context from my IDE")) {
            return nil
        }
        guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("Agent mail from"),
              !text.hasPrefix("The following is the Codex agent history"),
              // Later turns of that reviewer: numbered lines of the history it judges.
              text.range(of: #"^\[\d+\] (assistant|user|tool)"#, options: .regularExpression) == nil else { return nil }
        return text
    }

    public static func codexCwd(_ line: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              o["type"] as? String == "session_meta", let p = o["payload"] as? [String: Any] else { return nil }
        return p["cwd"] as? String
    }

    // MARK: - Data exports

    /// `conversations.json` from a ChatGPT export (Settings → Data controls →
    /// Export) or a Claude export (Settings → Privacy → Export data).
    public static func exportMessages(_ data: Data) -> [Message] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [Message] = []
        for c in list {
            if let mapping = c["mapping"] as? [String: Any] {
                let title = c["title"] as? String
                for (_, node) in mapping {
                    guard let n = node as? [String: Any], let m = n["message"] as? [String: Any],
                          (m["author"] as? [String: Any])?["role"] as? String == "user",
                          ((m["metadata"] as? [String: Any])?["is_visually_hidden_from_conversation"] as? Bool) != true,
                          let t = m["create_time"] as? Double else { continue }
                    let parts = ((m["content"] as? [String: Any])?["parts"] as? [Any] ?? []).compactMap { $0 as? String }
                    let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    out.append(Message(id: "gx-" + ((m["id"] as? String) ?? hash(text + "\(t)")),
                                       at: Date(timeIntervalSince1970: t), tool: "ChatGPT", conversation: title,
                                       text: text, source: .export))
                }
            } else if let msgs = c["chat_messages"] as? [[String: Any]] {
                let title = c["name"] as? String
                for m in msgs where m["sender"] as? String == "human" {
                    guard let at = date(m["created_at"] as? String) else { continue }
                    var text = (m["text"] as? String) ?? ""
                    if text.isEmpty {
                        text = (m["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    }
                    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    out.append(Message(id: "ce-" + ((m["uuid"] as? String) ?? hash(text + "\(at.timeIntervalSince1970)")),
                                       at: at, tool: "Claude", conversation: title, text: text, source: .export))
                }
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    /// One message per wording per tool per day, preferring exact times
    /// (export, transcript) over what a window read saw, and live window
    /// reads over backfill.
    public static func deduplicated(_ messages: [Message]) -> [Message] {
        func rank(_ m: Message) -> Int { m.source == .window ? (m.backfill ? 2 : 1) : 0 }
        var best: [String: Message] = [:]
        var order: [String] = []
        let cal = Calendar.current
        for m in messages {
            let k = m.textKey + "|" + "\(cal.startOfDay(for: m.at).timeIntervalSince1970)"
            if let b = best[k] {
                if rank(m) < rank(b) { best[k] = m }
            } else { best[k] = m; order.append(k) }
        }
        var out = order.compactMap { best[$0] }
        var exactKeys = Set<String>()
        var sameApp = Set<String>()
        for m in out where m.source != .window {
            exactKeys.insert(m.textKey)
            sameApp.insert(appKey(m, cal))
        }
        // The Claude app's window reader also sees what you type in its Code
        // tab, which the Claude Code transcript already has (likewise ChatGPT
        // and Codex, one app).
        out.removeAll { $0.source == .window && (($0.backfill && exactKeys.contains($0.textKey)) || sameApp.contains(appKey($0, cal))) }
        return out.sorted { $0.at < $1.at }
    }

    static func app(_ tool: String) -> String {
        switch tool {
        case "Claude Code": return "Claude"
        case "Codex": return "ChatGPT"
        default: return tool
        }
    }

    private static func appKey(_ m: Message, _ cal: Calendar) -> String {
        app(m.tool) + "|" + normalized(m.text) + "|" + "\(cal.startOfDay(for: m.at).timeIntervalSince1970)"
    }
}
