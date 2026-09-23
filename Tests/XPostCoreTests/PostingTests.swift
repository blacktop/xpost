import Foundation
import Testing

@testable import XPostCore

@Suite struct PostingTests {
  private struct Forbidden: Error {}

  private let recorder = Recorder()

  private func context(configured: Set<Target>, stdin: String? = nil) -> PostContext {
    PostContext(
      readStdin: { stdin }, makePublisher: recorder.makePublisher(configured: configured),
      style: .plain)
  }

  @Test func dryRunNeedsNoCredentialsAndNoStdin() async throws {
    let context = PostContext(
      readStdin: { throw Forbidden() }, makePublisher: { _ in throw Forbidden() }, style: .plain)
    let input = PostInput(
      message: "see https://example.com/page", link: " https://example.org/link ",
      targets: ["all"], dryRun: true)
    var output = ""

    try await post(input, context: context, output: &output)

    #expect(
      output == #"""
        [dry-run] Local text preview only; credentials, uploads, and server acceptance are not checked.
        [dry-run] would post to \#u{e28e} Bluesky: "see example.com/page\n\nexample.org/link"
        [dry-run] would post to \#u{edc0} Mastodon: "see https://example.com/page\n\nhttps://example.org/link"
        [dry-run] would post to \#u{f099} Twitter/X: "see https://example.com/page\n\nhttps://example.org/link"

        """#)
  }

  @Test func dryRunFailsForAMessageATargetRejects() async {
    let input = PostInput(
      message: String(repeating: "a", count: 301), targets: ["bluesky"], dryRun: true)
    var output = ""

    let error = await #expect(throws: PostFailure.self) {
      try await post(input, context: context(configured: []), output: &output)
    }
    #expect(
      error?.description
        == "bluesky: bluesky validation failed: message too long: 301 graphemes (max 300)")
  }

  @Test func dryRunDoesNotRequireTheImageToExist() async throws {
    let input = PostInput(
      argument: "hi", image: "./missing.png", targets: ["mastodon"], dryRun: true)
    var output = ""

    try await post(input, context: context(configured: []), output: &output)

    #expect(
      output.hasSuffix("[dry-run] image: ./missing.png (alt: \"Image attached via xpost\")\n"))
  }

  @Test(arguments: [[], ["all"], [" ALL "]])
  func defaultPolicyPostsToWhatIsConfigured(targets: [String]) async throws {
    var output = ""

    try await post(
      PostInput(message: "hi", targets: targets), context: context(configured: [.mastodon]),
      output: &output)

    #expect(recorder.published == [.mastodon])
    #expect(
      output == """
        Skipped \u{e28e} Bluesky: credentials not configured (missing XPOST_BLUESKY)
        Skipped \u{f099} Twitter/X: credentials not configured (missing XPOST_TWITTER)
        Posted to \u{edc0} Mastodon

        """)
  }

  @Test func namedTargetThatIsNotConfiguredFailsAfterPostingToTheRest() async {
    var output = ""

    let error = await #expect(throws: PostFailure.self) {
      try await post(
        PostInput(message: "hi", targets: ["mastodon,bluesky"]),
        context: context(configured: [.mastodon]), output: &output)
    }

    #expect(recorder.published == [.mastodon])
    #expect(error?.failures.map(\.target) == [.bluesky])
  }

  @Test func failsWithoutOutputWhenNothingIsConfigured() async {
    var output = ""

    let error = await #expect(throws: PostFailure.self) {
      try await post(PostInput(message: "hi"), context: context(configured: []), output: &output)
    }

    #expect(output.isEmpty)
    #expect(error?.failures.map(\.target) == [.bluesky, .mastodon, .twitter])
  }

  @Test func readsTheMessageFromStdin() async throws {
    var output = ""

    try await post(
      PostInput(targets: ["mastodon"], dryRun: true),
      context: context(configured: [], stdin: "piped\n"), output: &output)

    #expect(output.hasSuffix("Mastodon: \"piped\"\n"))
  }

  @Test func missingImageStopsTheRunBeforeAnythingIsPublished() async {
    var output = ""

    await #expect(throws: UsageError("image \"/nonexistent/shot.png\" not found")) {
      try await post(
        PostInput(message: "hi", image: "/nonexistent/shot.png"),
        context: context(configured: [.bluesky, .mastodon]), output: &output)
    }

    #expect(recorder.published.isEmpty)
    #expect(output.isEmpty)
  }

  @Test func passesTheImageAndAltTextToPublishers() async throws {
    let image = try temporaryImage()
    defer { try? FileManager.default.removeItem(at: image) }

    var output = ""

    try await post(
      PostInput(message: "hi", image: image.path, altText: "  a chart ", targets: ["mastodon"]),
      context: context(configured: [.mastodon]), output: &output)

    #expect(
      recorder.requests == [Request(message: "hi", imagePath: image.path, imageAlt: "a chart")])
  }

  @Test(arguments: [["threads"], [","]])
  func rejectsBadTargetsBeforeBuildingPublishers(targets: [String]) async {
    let context = PostContext(
      readStdin: { nil }, makePublisher: { _ in throw Forbidden() }, style: .plain)
    var output = ""

    await #expect(throws: UsageError.self) {
      try await post(PostInput(message: "hi", targets: targets), context: context, output: &output)
    }
  }
}
