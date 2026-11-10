import XCTest
@testable import FocusCore

final class RecruitingEvidenceTests: XCTestCase {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    func testConfirmationPageOnAHiringSite() {
        let a = RecruitingEvidence.application(title: "Jane Street - Software Engineer Intern",
            url: "https://boards.greenhouse.io/janestreet/jobs/123/confirmation",
            text: "Thank you for applying.\nWe'll be in touch.", app: "Google Chrome", at: t)
        XCTAssertEqual(a?.company, "Janestreet")
        XCTAssertEqual(a?.source, "page")
        let b = RecruitingEvidence.application(title: "Careers", url: "https://careers.citadel.com/apply",
            text: "Thank you for applying to Citadel! Your application has been received.", app: "Google Chrome", at: t)
        XCTAssertEqual(b?.company, "Citadel")
    }

    func testConfirmationEmail() {
        let a = RecruitingEvidence.application(title: "Thank you for applying to Hudson River Trading - melbournemagnus@gmail.com - Gmail",
            url: "https://mail.google.com/mail/u/0/#inbox/abc", text: "Hi Magnus, thank you for applying", app: "Google Chrome", at: t)
        XCTAssertEqual(a?.company, "Hudson River Trading")
        XCTAssertEqual(a?.source, "email")
    }

    func testNotEveryThankYou() {
        XCTAssertNil(RecruitingEvidence.application(title: "Order confirmed - Amazon", url: "https://amazon.com/x",
            text: "Thank you for your order", app: "Google Chrome", at: t))
        XCTAssertNil(RecruitingEvidence.application(title: "Linear algebra notes", url: nil,
            text: "applications of eigenvalues", app: "Preview", at: t))
        XCTAssertNil(RecruitingEvidence.application(title: "Inbox (3) - melbournemagnus@gmail.com - Gmail", url: "https://mail.google.com/mail/u/0/#inbox",
            text: "Thank you for applying to Two Sigma", app: "Google Chrome", at: t))
    }

    func testOneACompanyAWeek() {
        let a = RecruitingEvidence.Application(at: t, company: "Citadel", site: "careers.citadel.com", source: "page", title: "x")
        let b = RecruitingEvidence.Application(at: t + 600, company: "citadel", site: "email", source: "email", title: "y")
        let c = RecruitingEvidence.Application(at: t + 900, company: "Jane Street", site: "x", source: "page", title: "z")
        XCTAssertEqual(RecruitingEvidence.deduplicated([b, a, c]).map(\.title), ["x", "z"])
    }
}
