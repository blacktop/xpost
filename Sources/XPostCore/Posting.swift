import Foundation

/// The post command's input, as given on the command line.
public struct PostInput: Sendable {
  public var argument: String?
  public var message: String?
  public var link: String?
  public var image: String?
  public var altText: String?
  public var targets: [String]
  public var dryRun: Bool

  public init(
    argument: String? = nil, message: String? = nil, link: String? = nil, image: String? = nil,
    altText: String? = nil, targets: [String] = [], dryRun: Bool = false
  ) {
    self.argument = argument
    self.message = message
    self.link = link
    self.image = image
    self.altText = altText
    self.targets = targets
    self.dryRun = dryRun
  }
}

/// The process boundaries the post command reaches through.
public struct PostContext: Sendable {
  /// Returns piped stdin, or nil when stdin is a terminal.
  public var readStdin: @Sendable () async throws -> String?

  /// Builds the publisher for a target, throwing `NotConfigured` when it is not set up.
  public var makePublisher: @Sendable (Target) throws -> Publisher

  public var style: LabelStyle

  public init(
    readStdin: @escaping @Sendable () async throws -> String?,
    makePublisher: @escaping @Sendable (Target) throws -> Publisher,
    style: LabelStyle
  ) {
    self.readStdin = readStdin
    self.makePublisher = makePublisher
    self.style = style
  }
}

public let defaultAltText = "Image attached via xpost"

/// Runs the post command: resolve the input, then preview or publish to each target.
///
/// - Throws: `UsageError` for input that stops the run up front, and `PostFailure` when
///   any target was fatally skipped or failed to post.
public func post<Output: TextOutputStream>(
  _ input: PostInput, context: PostContext, output: inout Output
) async throws {
  let message = try await resolveMessage(
    argument: input.argument, option: input.message, readStdin: context.readStdin)
  let selection = try TargetSelection(input.targets)
  let request = makeRequest(message: message, input: input)

  let failures: [TargetFailure]
  if input.dryRun {
    print(
      "[dry-run] Local text preview only; credentials, uploads, and server acceptance "
        + "are not checked.", to: &output)
    // Previews only use request data, so no publisher is built and no credentials load.
    let posters = selection.targets.map { Poster(target: $0, publish: { _ in }) }
    failures = try await dispatch(
      request, to: posters, skips: [], mode: .dryRun, style: context.style, output: &output)
  } else {
    // Checked once here, before anything is sent, so a bad path cannot leave the post on
    // some networks and not others.
    if !request.imagePath.isEmpty && !FileManager.default.fileExists(atPath: request.imagePath) {
      throw UsageError("image \(quoted(request.imagePath)) not found")
    }
    let (posters, skips) = try makePosters(for: selection, using: context.makePublisher)
    failures = try await dispatch(
      request, to: posters, skips: skips, mode: .publish, style: context.style, output: &output)
  }

  if !failures.isEmpty {
    throw PostFailure(failures: failures)
  }
}

private func makeRequest(message: String, input: PostInput) -> Request {
  let imagePath = input.image ?? ""
  let altText = (input.altText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  return Request(
    message: message,
    link: (input.link ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
    imagePath: imagePath,
    imageAlt: altText.isEmpty && !imagePath.isEmpty ? defaultAltText : altText)
}
