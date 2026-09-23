import ArgumentParser
import Foundation
import XPostCore

struct Post: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Publish a message to the selected targets"
  )

  // A single optional word, so a mistyped subcommand such as "twitter login" is a parse
  // error instead of a post.
  @Argument(help: "Message text to post")
  var message: String?

  @Option(name: [.customShort("m"), .customLong("message")], help: "Message text to post")
  var messageOption: String?

  @Option(name: [.short, .long], help: "URL to append to the message after a blank line")
  var link: String?

  @Option(help: "Path to an image to attach")
  var image: String?

  @Option(help: "Alternative text to describe the image (default: \(defaultAltText))")
  var altText: String?

  @Option(
    help: """
      Targets to post to: twitter, mastodon, bluesky, or all. Repeat the option or \
      separate names with commas (default: all)
      """)
  var target: [String] = []

  @Flag(help: "Validate and preview locally without credentials or network requests")
  var dryRun = false

  @OptionGroup var verbosity: Verbosity

  @Flag(help: "Show the browser window while posting to X")
  var showBrowser = false

  func run() {
    let input = PostInput(
      argument: message, message: messageOption, link: link, image: image, altText: altText,
      targets: target, dryRun: dryRun)
    let environment = ProcessInfo.processInfo.environment
    let context = PostContext(
      readStdin: readPipedStdin,
      makePublisher: { [verbosity, showBrowser] in
        try makePublisher(
          for: $0, environment: environment, log: verbosity.log($0.rawValue),
          showsBrowser: showBrowser)
      },
      style: labelStyle(environment: environment))

    let loop = mainLoop(
      forPostingTo: target, dryRun: dryRun, showsBrowser: showBrowser, environment: environment)
    runToExit(loop) {
      var output = StandardOutput()
      try await post(input, context: context, output: &output)
    }
  }
}

struct StandardOutput: TextOutputStream {
  func write(_ string: String) {
    FileHandle.standardOutput.write(Data(string.utf8))
  }
}

@Sendable private func readPipedStdin() async throws -> String? {
  try await readPipedInput(from: FileHandle.standardInput)
}

private func labelStyle(environment: [String: String]) -> LabelStyle {
  let wantsColor = environment["NO_COLOR", default: ""].isEmpty && isatty(STDOUT_FILENO) != 0
  return wantsColor ? .ansi : .plain
}
