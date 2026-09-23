import Synchronization
import Testing

@testable import XPostCore

@Suite struct DispatchTests {
  private let recorder = Recorder()
  private let short = Request(message: "hi")

  // 301 characters: over Bluesky's limit, within Mastodon's and over Twitter's.
  private let tooLongForBluesky = Request(message: String(repeating: "a", count: 301))

  @Test func postsToTargetsThatAcceptWhenAnotherRejects() async throws {
    var output = ""
    let failures = try await dispatch(
      tooLongForBluesky, to: [recorder.poster(.bluesky), recorder.poster(.mastodon)], skips: [],
      mode: .publish, style: .plain, output: &output)

    #expect(recorder.published == [.mastodon])
    #expect(failures.map(\.target) == [.bluesky])
    // ValidationError already names the target; the skip line should not repeat it.
    #expect(
      output == """
        Skipped \u{e28e} Bluesky: message too long: 301 graphemes (max 300)
        Posted to \u{edc0} Mastodon

        """)
  }

  @Test func reportsWhenEveryTargetRejects() async throws {
    var output = ""
    let failures = try await dispatch(
      Request(message: String(repeating: "a", count: 501)),
      to: [recorder.poster(.bluesky), recorder.poster(.mastodon)], skips: [], mode: .publish,
      style: .plain, output: &output)

    #expect(recorder.published.isEmpty)
    #expect(failures.map(\.target) == [.bluesky, .mastodon])
    #expect(output.hasSuffix("No targets accepted the post\n"))
  }

  @Test func keepsGoingAfterAPostFails() async throws {
    var output = ""
    let failures = try await dispatch(
      short,
      to: [
        recorder.poster(.bluesky, failingWith: FakeFailure(description: "create record: 502")),
        recorder.poster(.mastodon),
      ], skips: [], mode: .publish, style: .plain, output: &output)

    #expect(recorder.published == [.bluesky, .mastodon])
    #expect(failures.map(\.description) == ["bluesky: create record: 502"])
    #expect(
      output == """
        error: \u{e28e} Bluesky: create record: 502
        Posted to \u{edc0} Mastodon

        """)
  }

  @Test func carriesUnconfiguredTargetsWithoutFailing() async throws {
    let skip = TargetSkip(
      target: .twitter, error: NotConfigured(target: .twitter, missing: ["XPOST_TWITTER_USER"]),
      isFatal: false)
    var output = ""
    let failures = try await dispatch(
      short, to: [recorder.poster(.mastodon)], skips: [skip], mode: .publish, style: .plain,
      output: &output)

    #expect(failures.isEmpty)
    #expect(recorder.published == [.mastodon])
    #expect(
      output.hasPrefix(
        "Skipped \u{f099} Twitter/X: credentials not configured (missing XPOST_TWITTER_USER)\n"))
  }

  @Test func reportsAFatalSkipAsAFailure() async throws {
    let skip = TargetSkip(
      target: .twitter, error: NotConfigured(target: .twitter, missing: []), isFatal: true)
    var output = ""
    let failures = try await dispatch(
      short, to: [recorder.poster(.mastodon)], skips: [skip], mode: .publish, style: .plain,
      output: &output)

    #expect(failures.map(\.description) == ["twitter: twitter credentials not configured"])
    #expect(recorder.published == [.mastodon])
    #expect(output.hasPrefix("Skipped \u{f099} Twitter/X: credentials not configured\n"))
  }

  @Test func dryRunPostsNothingAndRendersEachTargetsText() async throws {
    let request = Request(
      message: "see https://example.com/page", link: "https://example.org/link",
      imagePath: "./shot.png", imageAlt: "a \"shot\"")
    var output = ""
    let failures = try await dispatch(
      request, to: [recorder.poster(.bluesky), recorder.poster(.mastodon)], skips: [],
      mode: .dryRun, style: .plain, output: &output)

    #expect(failures.isEmpty)
    #expect(recorder.published.isEmpty)
    #expect(
      output == #"""
        [dry-run] would post to \#u{e28e} Bluesky: "see example.com/page\n\nexample.org/link"
        [dry-run] would post to \#u{edc0} Mastodon: "see https://example.com/page\n\nhttps://example.org/link"
        [dry-run] image: ./shot.png (alt: "a \"shot\"")

        """#)
  }

  @Test func dryRunStillReportsRejections() async throws {
    var output = ""
    let failures = try await dispatch(
      tooLongForBluesky, to: [recorder.poster(.bluesky)], skips: [], mode: .dryRun,
      style: .plain, output: &output)

    #expect(failures.map(\.target) == [.bluesky])
    #expect(output.hasSuffix("No targets accepted the post\n"))
  }

  @Test func ansiStyleColorsTargetNames() async throws {
    var output = ""
    _ = try await dispatch(
      short, to: [recorder.poster(.mastodon)], skips: [], mode: .publish, style: .ansi,
      output: &output)

    #expect(output == "Posted to \u{1B}[38;5;63m\u{edc0} Mastodon\u{1B}[0m\n")
  }
}

extension DispatchTests {
  @Test func anInterruptStopsTheRunInsteadOfCountingAsAFailure() async throws {
    let recorder = Recorder()
    let waiting = Poster(target: .bluesky) { _ in
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        throw FakeFailure(description: "post status: cancelled")
      }
    }
    let task = Task {
      var output = ""
      let failures = try await dispatch(
        Request(message: "hi"), to: [waiting, recorder.poster(.mastodon)], skips: [],
        mode: .publish, style: .plain, output: &output)
      return (failures, output)
    }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(recorder.published.isEmpty)
  }
}

extension DispatchTests {
  /// Cancelled from inside a publisher that then returns normally: the next one must not run.
  @Test func anInterruptDuringASuccessfulPostStopsTheRestOfTheRun() async throws {
    let recorder = Recorder()
    let handle = Mutex<Task<(failures: [TargetFailure], output: String), any Error>?>(nil)
    let interrupting = Poster(target: .bluesky) { _ in
      handle.withLock { $0 }?.cancel()
    }
    let task = Task {
      var output = ""
      let failures = try await dispatch(
        Request(message: "hi"), to: [interrupting, recorder.poster(.mastodon)], skips: [],
        mode: .publish, style: .plain, output: &output)
      return (failures: failures, output: output)
    }
    handle.withLock { $0 = task }

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(recorder.published.isEmpty)
  }
}

@Suite struct MakePostersTests {
  private let recorder = Recorder()

  @Test func defaultFanOutOnlyNotesUnconfiguredTargets() throws {
    let (posters, skips) = try makePosters(
      for: TargetSelection([]), using: recorder.makePublisher(configured: [.mastodon]))

    #expect(posters.map(\.target) == [.mastodon])
    #expect(skips.map(\.target) == [.bluesky, .twitter])
    #expect(skips.allSatisfy { !$0.isFatal })
  }

  @Test func namedTargetsMustBeConfigured() throws {
    let (posters, skips) = try makePosters(
      for: TargetSelection(["mastodon,bluesky"]),
      using: recorder.makePublisher(configured: [.mastodon]))

    #expect(posters.map(\.target) == [.mastodon])
    #expect(skips.map(\.target) == [.bluesky])
    #expect(skips.allSatisfy { $0.isFatal })
  }

  @Test func otherSetupFailuresAreAlwaysFatal() throws {
    let (_, skips) = try makePosters(for: TargetSelection([])) { target in
      if target == .twitter {
        throw FakeFailure(description: "passkey store unreadable")
      }
      return self.recorder.publisher(for: target)
    }

    #expect(skips.map(\.target) == [.twitter])
    #expect(skips.allSatisfy { $0.isFatal })
  }

  @Test func failsWithEveryReasonWhenNothingIsConfigured() throws {
    let error = #expect(throws: PostFailure.self) {
      try makePosters(for: TargetSelection([]), using: recorder.makePublisher(configured: []))
    }

    #expect(
      error?.description == """
        bluesky: bluesky credentials not configured (missing XPOST_BLUESKY)
        mastodon: mastodon credentials not configured (missing XPOST_MASTODON)
        twitter: twitter credentials not configured (missing XPOST_TWITTER)
        """)
  }
}
