import Foundation

/// A job application you sent, from what the screen showed: a confirmation
/// page on a hiring site ("Thank you for applying", "Application submitted")
/// or the confirmation email. Counted toward the recruiting goal without
/// asking; one per company per week.
public enum RecruitingEvidence {
    public struct Application: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var at: Date
        public var company: String?
        public var site: String
        public var source: String
        public var title: String

        public init(at: Date, company: String?, site: String, source: String, title: String) {
            self.at = at; self.company = company; self.site = site; self.source = source; self.title = title
            self.id = AIChats.hash("\(company?.lowercased() ?? site)|\(Int(at.timeIntervalSince1970 / (7 * 86400)))")
        }
    }

    static let confirmation = #"(?i)\b(thank(s| you) for (applying|your application|your interest in joining)|your application (has been|was) (submitted|received|sent)|application (submitted|received|complete)|we('ve| have) received your application|you('ve| have) (successfully )?applied|your application was sent)\b"#
    static let hiringHosts = ["greenhouse.io", "lever.co", "myworkdayjobs.com", "ashbyhq.com", "smartrecruiters.com",
                              "icims.com", "jobvite.com", "workable.com", "joinhandshake.com", "wellfound.com",
                              "linkedin.com/jobs", "careers.", "jobs.", "/careers", "/jobs"]

    public static func application(title: String, url: String?, text: String, app: String, at: Date) -> Application? {
        let body = String(text.prefix(6000))
        guard (title + "\n" + body).range(of: confirmation, options: .regularExpression) != nil else { return nil }
        let lowerURL = url?.lowercased() ?? ""
        let lowerTitle = title.lowercased()
        let isMail = lowerTitle.contains("gmail") || lowerTitle.contains("inbox") || app == "Mail" || lowerURL.contains("mail.google.com")
        let onHiringSite = hiringHosts.contains { lowerURL.contains($0) }
            || lowerTitle.range(of: #"\b(careers?|jobs?|application|apply|intern(ship)?|new grad)\b"#, options: .regularExpression) != nil
        guard isMail || onHiringSite else { return nil }
        if isMail, lowerTitle.range(of: #"^(inbox|gmail)\b"#, options: .regularExpression) != nil { return nil }
        let site = URL(string: url ?? "")?.host ?? (isMail ? "email" : app)
        return Application(at: at, company: company(title: title, url: url, text: body), site: site,
                           source: isMail ? "email" : "page", title: String(title.prefix(120)))
    }

    static func company(title: String, url: String?, text: String) -> String? {
        let pattern = #"(?:applying|application|interest in joining|applied) (?:to|at|for|with) ([A-Z][A-Za-z0-9&.'\- ]{1,40}?)(?:[!.,\n|–—-]| for | as |$)"#
        for s in [title, text] {
            if let r = s.range(of: pattern, options: .regularExpression) {
                let m = String(s[r])
                if let inner = m.range(of: #"(?:to|at|for|with) "#, options: .regularExpression) {
                    var name = String(m[inner.upperBound...])
                    name = name.trimmingCharacters(in: CharacterSet(charactersIn: "!.,|–—- \n"))
                    for cut in [" for ", " as "] { if let c = name.range(of: cut) { name = String(name[..<c.lowerBound]) } }
                    let words = Set(["the", "our", "this", "a", "your"])
                    if !name.isEmpty, !words.contains(name.lowercased()) { return name }
                }
            }
        }
        if let u = url.flatMap(URL.init(string:)), let host = u.host?.lowercased() {
            let parts = u.path.split(separator: "/").map(String.init)
            if host.contains("greenhouse.io") || host.contains("lever.co") || host.contains("ashbyhq.com"),
               let first = parts.first(where: { $0 != "embed" && $0 != "job_app" }) {
                return first.replacingOccurrences(of: "-", with: " ").capitalized
            }
            if host.contains("myworkdayjobs.com"), let sub = host.split(separator: ".").first { return String(sub).capitalized }
        }
        for sep in [" | ", " - ", " – ", " — "] {
            let parts = title.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count > 1, let last = parts.last, last.count <= 40, last.range(of: confirmation, options: .regularExpression) == nil,
               !["Google Chrome", "Gmail", "Careers", "Jobs"].contains(last) { return last }
        }
        return nil
    }

    /// One per company (or site) per calendar week, the earliest kept.
    public static func deduplicated(_ apps: [Application]) -> [Application] {
        var seen = Set<String>()
        return apps.sorted { $0.at < $1.at }.filter { seen.insert($0.id).inserted }
    }
}
