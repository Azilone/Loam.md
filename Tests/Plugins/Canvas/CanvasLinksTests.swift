import XCTest
@testable import CanvasPlugin

final class CanvasLinksTests: XCTestCase {
    func testKindsAreKnownFromTheAddress() {
        func kind(_ text: String) -> CanvasLinkKind { CanvasLinkKind(URL(string: text)!) }
        XCTAssertEqual(kind("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1"), .youtube(id: "dQw4w9WgXcQ"))
        XCTAssertEqual(kind("https://youtu.be/dQw4w9WgXcQ"), .youtube(id: "dQw4w9WgXcQ"))
        XCTAssertEqual(kind("https://youtube.com/shorts/abc123"), .youtube(id: "abc123"))
        XCTAssertEqual(kind("https://x.com/jack/status/20"), .tweet)
        XCTAssertEqual(kind("https://twitter.com/jack"), .page)
        XCTAssertEqual(kind("https://vimeo.com/76979871"), .vimeo)
        XCTAssertEqual(kind("https://example.com/paper.PDF"), .pdf)
        XCTAssertEqual(kind("https://www.linkedin.com/posts/someone_activity-1"), .page)
        XCTAssertEqual(CanvasLinkPreview.offline(URL(string: "https://youtu.be/abc")!)?.image?.absoluteString,
                       "https://i.ytimg.com/vi/abc/hqdefault.jpg")
    }

    func testPreviewsAreReadFromOpenGraph() {
        let html = """
        <html><head><title>Fallback</title>
        <meta property="og:title" content="Loam &amp; boards">
        <meta name='description' content="Plain description">
        <meta property="og:image" content="/img/cover.png" />
        <link rel="icon" href="/favicon.png">
        </head><body><meta property="og:title" content="ignored"></body></html>
        """
        let preview = CanvasLinkPreview(html: html, url: URL(string: "https://www.example.com/a/b")!)
        XCTAssertEqual(preview.title, "Loam & boards")
        XCTAssertEqual(preview.summary, "Plain description")
        XCTAssertEqual(preview.image?.absoluteString, "https://www.example.com/img/cover.png")
        XCTAssertEqual(preview.site, "example.com")
        XCTAssertEqual(preview.icon?.absoluteString, "https://www.example.com/favicon.png")
        XCTAssertEqual(CanvasLinkPreview(html: "<title>Only &#39;this&#x27;</title>", url: URL(string: "https://a.b")!).title,
                       "Only 'this'")
    }

    func testTweetsAreReadFromOEmbed() throws {
        let json = #"{"author_name":"Jack","author_url":"https://twitter.com/jack","html":"<blockquote class=\"twitter-tweet\"><p lang=\"en\" dir=\"ltr\">just setting up my <a href=\"x\">twttr</a><br>ok &amp; done</p>&mdash; jack</blockquote>"}"#
        let preview = try XCTUnwrap(CanvasLinkPreview(tweetOEmbed: Data(json.utf8)))
        XCTAssertEqual(preview.title, "Jack")
        XCTAssertEqual(preview.author, "@jack")
        XCTAssertEqual(preview.summary, "just setting up my twttr\nok & done")
    }
}
