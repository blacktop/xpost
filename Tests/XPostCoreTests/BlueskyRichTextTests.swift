import Testing

@testable import XPostCore

@Suite struct BlueskyRichTextTests {
  @Test(arguments: [
    ("https://example.com", "example.com"),
    ("https://example.com/", "example.com"),
    ("https://github.com/blacktop/xpost", "github.com/blacktop/xpost"),
    ("https://github.com/blacktop/xpost/releases/latest", "github.com/blacktop/xpo..."),
    ("https://example.com/a?b=c", "example.com/a?b=c"),
    ("https://example.com/search?q=something+long+here", "example.com/search?q=som..."),
    ("https://example.com:8080/a", "example.com:8080/a"),
    ("https://example.com/#", "example.com"),
    ("ftp://example.com/files/archive", "ftp://example.com/files/archive"),
  ])
  func shortensURLLikeTheBlueskyComposer(raw: String, want: String) {
    #expect(shortenURL(raw) == want)
  }

  @Test func linksFullURLBehindShortLabel() throws {
    let full = "https://github.com/blacktop/xpost/releases/latest"
    let (text, facets) = renderBlueskyPost("check \(full) out")

    #expect(text == "check github.com/blacktop/xpo... out")
    let facet = try #require(facets.first)
    #expect(facets.count == 1)
    #expect(facet.uri == full)
    #expect(try slice(text, facet) == "github.com/blacktop/xpo...")
  }

  @Test func byteOffsetsSurviveMultibyteText() throws {
    let (text, facets) = renderBlueskyPost("🎉 https://example.com/very/long/path/here")

    // The emoji is 4 bytes, so a character-based offset would point into the middle of it.
    let facet = try #require(facets.first)
    #expect(facet.byteStart == 5)
    #expect(try slice(text, facet) == "example.com/very/long/pa...")
  }

  @Test func rendersEveryLinkWithOffsetsIntoTheRewrittenText() throws {
    let (text, facets) = renderBlueskyPost(
      "a https://example.com/first/long/path/1 b https://example.org/x c")

    #expect(text == "a example.com/first/long/p... b example.org/x c")
    #expect(
      try facets.map { try slice(text, $0) } == [
        "example.com/first/long/p...", "example.org/x",
      ])
    #expect(
      facets.map(\.uri) == [
        "https://example.com/first/long/path/1", "https://example.org/x",
      ])
  }

  @Test func leavesTrailingPunctuationOutOfTheLink() throws {
    let (text, facets) = renderBlueskyPost("see https://example.com/page.")

    #expect(text == "see example.com/page.")
    let facet = try #require(facets.first)
    #expect(facet.uri == "https://example.com/page")
    #expect(try slice(text, facet) == "example.com/page")
  }

  @Test func preservesBalancedURLParentheses() throws {
    let (text, facets) = renderBlueskyPost("(https://example.com/a(b)).")

    #expect(text == "(example.com/a(b)).")
    let facet = try #require(facets.first)
    #expect(facet.uri == "https://example.com/a(b)")
    #expect(try slice(text, facet) == "example.com/a(b)")
  }

  @Test(arguments: ["no links here", "", "https:// is not a link", "ftp://example.com/x"])
  func leavesTextWithoutLinksUnchanged(text: String) {
    let rendered = renderBlueskyPost(text)

    #expect(rendered.text == text)
    #expect(rendered.facets.isEmpty)
  }

  @Test func stopsALinkAtAnyASCIIWhitespace() {
    let rendered = renderBlueskyPost("https://example.com/a\nnext\thttps://example.org/b")

    #expect(rendered.text == "example.com/a\nnext\texample.org/b")
    #expect(rendered.facets.map(\.uri) == ["https://example.com/a", "https://example.org/b"])
  }

  /// The substring a facet's byte range points at; fails if the range is out of bounds.
  private func slice(_ text: String, _ facet: BlueskyLinkFacet) throws -> String {
    let bytes = Array(text.utf8)
    try #require(facet.byteStart >= 0 && facet.byteStart <= facet.byteEnd)
    try #require(facet.byteEnd <= bytes.count)
    return String(decoding: bytes[facet.byteStart..<facet.byteEnd], as: UTF8.self)
  }
}
