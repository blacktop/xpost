import Foundation
import Testing

@testable import XPostChromium

/// The real runner against /bin/sh, so no Node is needed to prove how children are handled.
@Suite struct ProcessRunnerTests {
  private let runner = processHelperRunner()

  private func shell(_ script: String, input: String = "", timeout: TimeInterval = 10)
    -> HelperInvocation
  {
    HelperInvocation(
      executable: "/bin/sh", arguments: ["-c", script], input: Data(input.utf8), timeout: timeout)
  }

  @Test func passesStdinAndCollectsBothStreams() async throws {
    let output = try await runner(
      shell(#"read line; echo "got $line"; echo "note" >&2; exit 0"#, input: "secret\n"))

    #expect(output.termination == .exited(0))
    #expect(String(decoding: output.stdout, as: UTF8.self) == "got secret\n")
    #expect(String(decoding: output.stderr, as: UTF8.self) == "note\n")
  }

  @Test func reportsANonZeroExit() async throws {
    let output = try await runner(shell("cat >/dev/null; exit 3"))

    #expect(output.termination == .exited(3))
  }

  @Test func keepsOutputUpToTheLimit() async throws {
    let output = try await runner(shell("cat >/dev/null; head -c \(helperOutputLimit) /dev/zero"))

    #expect(output.stdout.count == helperOutputLimit)
  }

  @Test(arguments: [("stdout", ""), ("stderr", " >&2")])
  func stopsAChildThatWritesPastTheLimit(stream: String, redirect: String) async throws {
    let started = ContinuousClock.now

    let output = try await runner(shell("cat >/dev/null; yes\(redirect)", timeout: 30))

    #expect(output.termination == .overflowed(stream: stream))
    #expect(ContinuousClock.now - started < .seconds(10))
  }

  @Test func stopsAChildThatOutlivesItsBudget() async throws {
    let started = Date()
    let output = try await runner(shell("cat >/dev/null; sleep 30; echo late", timeout: 1))

    #expect(output.termination == .timedOut)
    #expect(output.stdout.isEmpty)
    #expect(Date().timeIntervalSince(started) < 10)
  }

  // More input than a pipe holds, to a child that reads nothing: the budget still applies.
  @Test func aChildThatNeverReadsItsInputStillHitsTheBudget() async throws {
    let started = Date()
    let output = try await runner(
      shell("sleep 30", input: String(repeating: "x", count: 300_000), timeout: 0.5))

    #expect(output.termination == .timedOut)
    #expect(Date().timeIntervalSince(started) < 8)
  }

  @Test func aChildThatExitsWithoutReadingDoesNotKillTheParent() async throws {
    let output = try await runner(
      shell("exit 4", input: String(repeating: "x", count: 300_000), timeout: 5))

    #expect(output.termination == .exited(4))
  }

  @Test func cancellationStopsTheChild() async throws {
    let started = Date()
    let task = Task { try await runner(shell("cat >/dev/null; sleep 30; echo late", timeout: 60)) }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date().timeIntervalSince(started) < 10)
  }

  @Test func aMissingExecutableThrows() async {
    let invocation = HelperInvocation(
      executable: "/nonexistent/node", arguments: [], input: Data(), timeout: 5)

    await #expect(throws: (any Error).self) { try await runner(invocation) }
  }
}
