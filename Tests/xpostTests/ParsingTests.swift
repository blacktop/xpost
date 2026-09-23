import ArgumentParser
import Testing

@testable import xpost

@Suite struct ParsingTests {
  @Test func aBareMessageRunsThePostCommand() throws {
    let command = try #require(try XPost.parseAsRoot(["Ship it!", "--dry-run"]) as? Post)

    #expect(command.message == "Ship it!")
    #expect(command.dryRun)
    #expect(command.target.isEmpty)
  }

  @Test func optionsAloneRunThePostCommand() throws {
    let command = try #require(
      try XPost.parseAsRoot([
        "-m", "hi", "-l", "https://example.com", "--image", "a.png", "--alt-text", "alt",
        "--target", "twitter", "--target", "mastodon,bluesky",
      ]) as? Post)

    #expect(command.message == nil)
    #expect(command.messageOption == "hi")
    #expect(command.link == "https://example.com")
    #expect(command.image == "a.png")
    #expect(command.altText == "alt")
    #expect(command.target == ["twitter", "mastodon,bluesky"])
    #expect(!command.dryRun)
  }

  @Test func twitterIsASubcommandNotAMessage() throws {
    #expect(try XPost.parseAsRoot(["twitter"]) is Twitter)
  }

  // A second word must not be folded into the message, or a mistyped subcommand such as
  // "twitter login" would be published.
  @Test(arguments: [["twitter", "login"], ["hello", "world"], ["post", "hello", "world"]])
  func rejectsASecondWord(arguments: [String]) {
    #expect(throws: (any Error).self) { try XPost.parseAsRoot(arguments) }
  }

  @Test func rejectsAnUnknownOption() {
    #expect(throws: (any Error).self) {
      try XPost.parseAsRoot(["--targets", "all", "--dry-run", "-m", "hi"])
    }
  }
}
