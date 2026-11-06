import XCTest
@testable import FocusCore

final class ReadingListTests: XCTestCase {
    func testURLKeyDropsTrackingAndFragment() {
        XCTAssertEqual(ReadingURL.key("http://www.Example.com/a/?utm_source=x&id=3#top"), "https://example.com/a?id=3")
        XCTAssertEqual(ReadingURL.key("https://example.com/a/"), ReadingURL.key("https://www.example.com/a?fbclid=1"))
    }

    func testReadwiseListPage() throws {
        let json = """
        {"count": 3, "nextPageCursor": "abc", "results": [
          {"id": "d1", "url": "https://read.readwise.io/read/d1", "source_url": "https://www.theatlantic.com/x/", "title": "An essay",
           "author": "Jane Doe", "category": "article", "location": "later", "tags": {"focus-blocked": {"name": "focus-blocked"}},
           "site_name": "The Atlantic", "word_count": 2400, "reading_progress": 0.4, "saved_at": "2026-10-23T14:02:11.123456+00:00",
           "created_at": "2026-10-23T14:02:11.123456+00:00", "html_content": "<p>Hello</p>"},
          {"id": "h1", "category": "highlight", "parent_id": "d1", "content": "A line worth keeping", "notes": "",
           "location": null, "created_at": "2026-10-24T10:00:00Z", "url": "https://read.readwise.io/read/h1"},
          {"id": "f1", "category": "rss", "location": "feed", "url": "https://blog.example/post", "title": "Feed item"}
        ]}
        """
        let page = try ReadwiseImport.parseListPage(Data(json.utf8))
        XCTAssertEqual(page.nextCursor, "abc")
        XCTAssertEqual(page.documents.count, 2)
        let doc = try XCTUnwrap(page.documents.first?.item)
        XCTAssertEqual(doc.url, "https://www.theatlantic.com/x/")
        XCTAssertEqual(doc.location, .later)
        XCTAssertEqual(doc.tags, ["focus-blocked"])
        XCTAssertEqual(doc.progress, 0.4, accuracy: 0.001)
        XCTAssertTrue(doc.hasContent)
        XCTAssertNotNil(ReadwiseImport.parseDate("2026-10-23T14:02:11.123456+00:00"))
        let h = try XCTUnwrap(page.documents.last?.highlight)
        XCTAssertEqual(h.parent, "d1")
        XCTAssertEqual(h.value.text, "A line worth keeping")
        XCTAssertNil(h.value.note)
    }

    func testReaderLibraryCSV() {
        let csv = "\u{FEFF}Title,URL,ID,Document tags,Saved date,Reading progress,Location,Seen\r\n"
            + "\"Hello, world\",https://example.com/a,01abc,\"['ml', 'read']\",2026-10-20 12:00:00+00:00,0.25,later,True\r\n"
            + "Feed,https://example.com/f,02,,2026-10-20,0,feed,False\r\n"
            + "\"Quote \"\"x\"\"\",https://example.com/b,03,,2026-10-21,75%,archive,True\r\n"
        let r = ReadwiseImport.parseCSV(csv)
        XCTAssertEqual(r.items.count, 2)
        XCTAssertEqual(r.items[0].title, "Hello, world")
        XCTAssertEqual(r.items[0].tags, ["ml", "read"])
        XCTAssertEqual(r.items[0].location, .later)
        XCTAssertEqual(r.items[1].title, "Quote \"x\"")
        XCTAssertEqual(r.items[1].progress, 0.75, accuracy: 0.001)
        XCTAssertEqual(r.items[1].location, .archive)
    }

    func testHighlightsCSV() {
        let csv = """
        Highlight,Book Title,Book Author,Amazon Book ID,Note,Color,Tags,Location Type,Location,Highlighted at,Document tags
        "Line one
        continues",An essay,Jane Doe,,my note,yellow,,,,2026-10-24 10:00:00+00:00,
        """
        let r = ReadwiseImport.parseCSV(csv)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertEqual(r.highlightsByTitle["An essay"]?.first?.text, "Line one\ncontinues")
        XCTAssertEqual(r.highlightsByTitle["An essay"]?.first?.note, "my note")
    }
}
