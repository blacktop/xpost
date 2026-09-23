import Testing

@testable import XPostCore

@Suite struct TargetTests {
  @Test(arguments: [(Target.bluesky, 300), (.mastodon, 500), (.twitter, 280)])
  func acceptsTheLimitAndRejectsOneMore(target: Target, limit: Int) throws {
    try target.validate(Request(message: String(repeating: "a", count: limit)))

    let error = #expect(throws: ValidationError.self) {
      try target.validate(Request(message: String(repeating: "a", count: limit + 1)))
    }
    #expect(error?.target == target)
    #expect(error?.reason.hasPrefix("message too long: \(limit + 1) ") == true)
    #expect(error?.reason.hasSuffix("(max \(limit))") == true)
  }

  @Test func countsTheLinkAgainstTheLimit() {
    let request = Request(message: String(repeating: "a", count: 270), link: "https://a.example")

    #expect(throws: ValidationError.self) { try Target.twitter.validate(request) }
    #expect(throws: Never.self) { try Target.mastodon.validate(request) }
  }

  @Test func blueskyCountsTheShortenedLink() throws {
    // A URL that blows the 300-grapheme budget at full length but fits once shortened.
    let long = "https://example.com/" + String(repeating: "a", count: 400)

    try Target.bluesky.validate(Request(message: "ship it", link: long))
  }

  @Test func blueskyCountsGraphemesWhileOthersCountScalars() throws {
    // One family emoji is a single grapheme made of seven scalars.
    let families = String(repeating: "👨‍👩‍👧‍👦", count: 41)

    try Target.bluesky.validate(Request(message: families))
    let error = #expect(throws: ValidationError.self) {
      try Target.twitter.validate(Request(message: families))
    }
    #expect(error?.reason == "message too long: 287 characters (max 280)")
  }

  @Test func previewsTheTextEachTargetCarries() {
    let request = Request(
      message: "see https://example.com/page", link: "https://example.org/link")

    #expect(Target.bluesky.preview(request) == "see example.com/page\n\nexample.org/link")
    #expect(
      Target.mastodon.preview(request)
        == "see https://example.com/page\n\nhttps://example.org/link")
    #expect(Target.twitter.preview(Request(message: "plain text")) == "plain text")
  }

  @Test func colorsLabelsOnlyInANSIStyle() {
    #expect(Target.mastodon.styled(.plain) == "\u{edc0} Mastodon")
    #expect(Target.mastodon.styled(.ansi) == "\u{1B}[38;5;63m\u{edc0} Mastodon\u{1B}[0m")
  }
}
