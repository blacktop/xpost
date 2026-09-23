import Foundation
import Testing

@testable import XPostCore

@Suite struct TargetSelectionTests {
  @Test func defaultsToEveryTargetWithoutRequiringThem() throws {
    let selection = try TargetSelection([])

    #expect(selection.targets == [.bluesky, .mastodon, .twitter])
    #expect(!selection.isExplicit)
  }

  @Test(arguments: [["all"], [" ALL "], ["mastodon", "all"], ["bluesky,all"]])
  func allUsesTheDefaultPolicy(values: [String]) throws {
    let selection = try TargetSelection(values)

    #expect(selection.targets == [.bluesky, .mastodon, .twitter])
    #expect(!selection.isExplicit)
  }

  @Test(arguments: [
    ["twitter", "bluesky"], ["twitter,bluesky"], [" Twitter , BLUESKY ,, twitter"],
  ])
  func namedTargetsAreSortedDeduplicatedAndExplicit(values: [String]) throws {
    let selection = try TargetSelection(values)

    #expect(selection.targets == [.bluesky, .twitter])
    #expect(selection.isExplicit)
  }

  @Test func rejectsAnUnknownTarget() {
    #expect(throws: UsageError("unsupported target \"threads\"")) {
      try TargetSelection(["mastodon,threads"])
    }
  }

  @Test(arguments: [[""], [" , "]])
  func rejectsASelectionThatNamesNothing(values: [String]) {
    #expect(throws: UsageError("no targets selected")) { try TargetSelection(values) }
  }
}

@Suite struct MessageTests {
  private struct StdinUnavailable: Error {}

  @Test func prefersTheArgumentOrTheOptionWithoutTouchingStdin() async throws {
    let failingStdin: () async throws -> String? = { throw StdinUnavailable() }

    #expect(
      try await resolveMessage(argument: " hi ", option: nil, readStdin: failingStdin) == "hi")
    #expect(
      try await resolveMessage(argument: nil, option: "hello\n", readStdin: failingStdin)
        == "hello")
  }

  @Test func rejectsBothArgumentAndOption() async {
    await #expect(throws: UsageError.self) {
      try await resolveMessage(argument: "a", option: "b", readStdin: { nil })
    }
  }

  @Test func fallsBackToPipedStdin() async throws {
    #expect(
      try await resolveMessage(argument: nil, option: nil, readStdin: { "  piped\n" }) == "piped"
    )
  }

  @Test func surfacesAStdinReadFailure() async {
    await #expect(throws: StdinUnavailable.self) {
      try await resolveMessage(
        argument: nil, option: nil, readStdin: { throw StdinUnavailable() })
    }
  }

  @Test(arguments: [nil, "", " \n\t "])
  func requiresAMessage(stdin: String?) async {
    await #expect(throws: UsageError("message is required")) {
      try await resolveMessage(argument: "  ", option: nil, readStdin: { stdin })
    }
  }
}

@Suite struct PipedInputTests {
  @Test func cancellationBeforeTheReadDoesNotWaitForEOF() async throws {
    let pipe = Pipe()
    // Bound a regression's wait: the old implementation missed this cancellation.
    let closer = Task {
      try await Task.sleep(for: .milliseconds(500))
      try pipe.fileHandleForWriting.close()
    }
    let started = ContinuousClock.now
    let reader = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await readPipedInput(from: pipe.fileHandleForReading)
    }
    await #expect(throws: CancellationError.self) { try await reader.value }
    #expect(ContinuousClock.now - started < .milliseconds(400))
    try await closer.value
  }

  @Test func racingEOFAndCancellationResumesOnlyOnce() async throws {
    for iteration in 0..<200 {
      let pipe = Pipe()
      let reader = Task { try await readPipedInput(from: pipe.fileHandleForReading) }
      let closer = Task.detached {
        if iteration.isMultiple(of: 2) { reader.cancel() }
        try pipe.fileHandleForWriting.close()
        reader.cancel()
      }
      do {
        #expect(try await reader.value == "")
      } catch is CancellationError {
        // Either completion can win; neither may resume an already-owned continuation.
      }
      try await closer.value
    }
  }

  @Test func readsAPipeToItsEnd() async throws {
    let pipe = Pipe()
    pipe.fileHandleForWriting.write(Data("piped ".utf8))
    let reader = Task { try await readPipedInput(from: pipe.fileHandleForReading) }
    pipe.fileHandleForWriting.write(Data("message\n".utf8))
    try pipe.fileHandleForWriting.close()

    #expect(try await reader.value == "piped message\n")
  }

  @Test func anInterruptDoesNotWaitForTheWriter() async throws {
    let pipe = Pipe()
    let reader = Task { try await readPipedInput(from: pipe.fileHandleForReading) }
    try await Task.sleep(for: .milliseconds(200))
    let started = Date()

    reader.cancel()

    await #expect(throws: CancellationError.self) { try await reader.value }
    #expect(Date().timeIntervalSince(started) < 2)
    try pipe.fileHandleForWriting.close()
  }
}

@Suite struct QuotingTests {
  @Test(arguments: [
    ("plain", "\"plain\""),
    ("two\n\nlines", "\"two\\n\\nlines\""),
    ("say \"hi\" \\ bye", "\"say \\\"hi\\\" \\\\ bye\""),
    ("tab\tcr\r", "\"tab\\tcr\\r\""),
    ("bell\u{07}soh\u{01}del\u{7F}", "\"bell\\asoh\\x01del\\x7f\""),
    ("🎉 é", "\"🎉 é\""),
  ])
  func escapesControlCharactersAndKeepsPrintableText(text: String, want: String) {
    #expect(quoted(text) == want)
  }
}
