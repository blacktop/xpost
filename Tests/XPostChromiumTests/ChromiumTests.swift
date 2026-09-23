import Foundation
import Synchronization
import Testing
import XPostCore

@testable import XPostChromium

/// A helper directory with a `dist/helper.js` in it, so the configuration accepts it.
func temporaryHelperDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "xpost-chromium-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory.appending(path: "dist"), withIntermediateDirectories: true)
  try Data("// stub".utf8).write(to: directory.appending(path: "dist/helper.js"))
  return directory
}

let testLog = RunLog(category: "test", isVerbose: false)

/// Records invocations and answers each with the next canned output.
final class RunnerStub: Sendable {
  private let state: Mutex<(replies: [HelperOutput], calls: [HelperInvocation])>

  init(_ replies: [HelperOutput]) {
    state = Mutex((replies, []))
  }

  var calls: [HelperInvocation] { state.withLock { $0.calls } }

  /// The JSON request the helper would have read on stdin.
  func request(_ index: Int = 0) throws -> NSDictionary {
    let input = try #require(calls.count > index ? calls[index].input : nil)
    return try #require(try JSONSerialization.jsonObject(with: input) as? NSDictionary)
  }

  var runner: HelperRunner {
    { invocation in
      let reply = self.state.withLock { state -> HelperOutput? in
        state.calls.append(invocation)
        return state.replies.isEmpty ? nil : state.replies.removeFirst()
      }
      return try #require(reply)
    }
  }
}

func output(_ json: String, termination: HelperTermination = .exited(0), stderr: String = "")
  -> HelperOutput
{
  HelperOutput(termination: termination, stdout: Data(json.utf8), stderr: Data(stderr.utf8))
}

@Suite struct ChromiumConfigTests {
  private let helper = try! temporaryHelperDirectory()

  private var complete: [String: String] {
    [
      "XPOST_TWITTER_HELPER": helper.path, "XPOST_TWITTER_USER": " fixture_user ",
      "XPOST_TWITTER_ACCOUNT_ID": "442174011", "XPOST_TWITTER_PASSWORD": "pw",
    ]
  }

  @Test func readsEverySetting() throws {
    var environment = complete
    environment["XPOST_TWITTER_STATE_FILE"] = "/tmp/state.json"
    environment["XPOST_TWITTER_BASE_URL"] = "http://127.0.0.1:1234"

    let config = try ChromiumConfig(environment: environment)

    #expect(config.helperScript == helper.appending(path: "dist/helper.js").path)
    #expect(config.user == "fixture_user")
    #expect(config.accountID == "442174011")
    #expect(config.password == "pw")
    #expect(config.stateFile == "/tmp/state.json")
    #expect(config.baseURL == "http://127.0.0.1:1234")
  }

  @Test func defaultsToXAndAcceptsAStateFileInsteadOfAPassword() throws {
    var environment = complete
    environment["XPOST_TWITTER_PASSWORD"] = nil
    environment["XPOST_TWITTER_STATE_FILE"] = "/tmp/state.json"

    let config = try ChromiumConfig(environment: environment)

    #expect(config.password == nil)
    #expect(config.baseURL == "https://x.com")
  }

  @Test func namesEveryMissingSetting() {
    #expect(
      throws: NotConfigured(
        target: .twitter,
        missing: ["XPOST_TWITTER_HELPER", "XPOST_TWITTER_USER", "XPOST_TWITTER_ACCOUNT_ID"],
        hint: "set XPOST_TWITTER_PASSWORD or XPOST_TWITTER_STATE_FILE to sign in")
    ) { try ChromiumConfig(environment: [:]) }
  }

  @Test func needsAPasswordOrAStateFile() {
    var environment = complete
    environment["XPOST_TWITTER_PASSWORD"] = ""

    #expect(
      throws: NotConfigured(
        target: .twitter, missing: [],
        hint: "set XPOST_TWITTER_PASSWORD or XPOST_TWITTER_STATE_FILE to sign in")
    ) { try ChromiumConfig(environment: environment) }
  }

  @Test func keepsThePasswordByteForByte() throws {
    var environment = complete
    environment["XPOST_TWITTER_PASSWORD"] = "  spaced pass\n"

    #expect(try ChromiumConfig(environment: environment).password == "  spaced pass\n")
  }

  // Arabic-Indic digits are numbers to Swift but not to the helper.
  @Test(arguments: ["blacktop", "\u{0664}\u{0664}\u{0662}"])
  func rejectsANonNumericAccountID(accountID: String) {
    var environment = complete
    environment["XPOST_TWITTER_ACCOUNT_ID"] = accountID

    #expect(throws: InvalidSetting.self) { try ChromiumConfig(environment: environment) }
  }

  @Test func rejectsAHelperDirectoryWithoutTheBuiltScript() {
    var environment = complete
    environment["XPOST_TWITTER_HELPER"] = FileManager.default.temporaryDirectory.path

    let error = #expect(throws: InvalidSetting.self) {
      try ChromiumConfig(environment: environment)
    }
    #expect(error?.description.contains("pnpm build") == true)
  }
}

@Suite struct ChromiumPublisherTests {
  private let helper = try! temporaryHelperDirectory()

  private var environment: [String: String] {
    [
      "XPOST_TWITTER_HELPER": helper.path, "XPOST_TWITTER_USER": "fixture_user",
      "XPOST_TWITTER_ACCOUNT_ID": "442174011", "XPOST_TWITTER_PASSWORD": "fixture-password",
      "XPOST_TWITTER_STATE_FILE": "/tmp/state.json",
    ]
  }

  private let posted = #"""
    {"outcome":"posted","accountID":"442174011","sessionSource":"state","stateSaved":false,"notice":"Your post was sent."}
    """#

  @Test func buildingThePublisherRunsNothing() throws {
    let stub = RunnerStub([])

    _ = try chromiumPublisher(environment: environment, runner: stub.runner, log: testLog)

    #expect(stub.calls.isEmpty)
  }

  @Test func sendsTheRequestOnStdinNotInArguments() async throws {
    let stub = RunnerStub([output(posted)])
    let publisher = try chromiumPublisher(
      environment: environment, runner: stub.runner, log: testLog)

    try await publisher(
      Request(message: "hi", link: "https://example.com", imagePath: "/tmp/shot.png"))

    let call = try #require(stub.calls.first)
    #expect(call.executable == "/usr/bin/env")
    #expect(call.arguments == ["node", helper.appending(path: "dist/helper.js").path])
    #expect(call.timeout == helperBudget)
    let request = try stub.request()
    #expect(request["op"] as? String == "post")
    #expect(request["username"] as? String == "fixture_user")
    #expect(request["password"] as? String == "fixture-password")
    #expect(request["accountID"] as? String == "442174011")
    #expect(request["stateFile"] as? String == "/tmp/state.json")
    #expect(request["baseURL"] as? String == "https://x.com")
    #expect(request["text"] as? String == "hi\n\nhttps://example.com")
    #expect(request["imagePath"] as? String == "/tmp/shot.png")
    #expect((request["timeoutMs"] as? Int).map { $0 < Int(helperBudget * 1000) } == true)
    let screenshot = try #require(request["screenshotPath"] as? String)
    #expect(screenshot.hasSuffix("/twitter-failed.png"))
    // A post that left no screenshot leaves no directory behind either.
    let directory = (screenshot as NSString).deletingLastPathComponent
    #expect(!FileManager.default.fileExists(atPath: directory))
  }

  @Test func everyRunGetsItsOwnScreenshotDirectory() async throws {
    let stub = RunnerStub([output(posted), output(posted)])
    let publisher = try chromiumPublisher(
      environment: environment, runner: stub.runner, log: testLog)

    try await publisher(Request(message: "one"))
    try await publisher(Request(message: "two"))

    #expect(
      try stub.request(0)["screenshotPath"] as? String != stub.request(1)["screenshotPath"]
        as? String
    )
  }

  @Test func omitsTheImageWhenThereIsNone() async throws {
    let stub = RunnerStub([output(posted)])
    let publisher = try chromiumPublisher(
      environment: environment, runner: stub.runner, log: testLog)

    try await publisher(Request(message: "hi"))

    #expect(try stub.request()["imagePath"] == nil)
  }

  @Test(arguments: [
    ("wrongAccount", "signed in as X user id 999, expected 442174011"),
    ("challenge", "X asked for a verification step at /account/access; finish it by hand"),
    ("ambiguous", "X did not confirm the post"),
    ("uploadFailed", "image upload failed: Media upload failed."),
    ("loginFailed", "X rejected the sign-in: Wrong password!"),
    ("notSignedIn", "no password was given"),
    ("timeout", "out of time during pressing Post"),
  ])
  func reportsEachHelperFailureOnceWithoutRetrying(reason: String, detail: String) async throws {
    let json =
      #"{"outcome":"failed","reason":"\#(reason)","detail":"\#(detail)","screenshot":"/tmp/x.png"}"#
    let stub = RunnerStub([output(json), output(posted)])
    let publisher = try chromiumPublisher(
      environment: environment, runner: stub.runner, log: testLog)

    let error = await #expect(throws: HelperFailure.self) {
      try await publisher(Request(message: "hi"))
    }

    #expect(error?.reason == reason)
    #expect(error?.description == "\(reason): \(detail) (screenshot: /tmp/x.png)")
    #expect(stub.calls.count == 1)
  }

  @Test(arguments: [
    (HelperTermination.timedOut, "helper did not finish within 180s and was stopped"),
    (.overflowed(stream: "stdout"), "helper wrote more than 1024 KiB to stdout and was stopped"),
  ])
  func aStoppedHelperIsAFailureNotARetry(termination: HelperTermination, message: String)
    async throws
  {
    let stub = RunnerStub([output("", termination: termination), output(posted)])
    let publisher = try chromiumPublisher(
      environment: environment, runner: stub.runner, log: testLog)

    let error = await #expect(throws: Failure.self) { try await publisher(Request(message: "hi")) }

    #expect(error?.description == message)
    #expect(stub.calls.count == 1)
  }

  @Test func aCrashedHelperReportsItsStatusAndLastLine() async throws {
    let stub = RunnerStub([
      output(
        "", termination: .exited(2),
        stderr: "helper: starting\nhelper: bad request: text is required\n")
    ])
    let publisher = try chromiumPublisher(
      environment: environment, runner: stub.runner, log: testLog)

    let error = await #expect(throws: Failure.self) { try await publisher(Request(message: "hi")) }

    #expect(
      error?.description == "helper exited with status 2: helper: bad request: text is required")
  }

  @Test(arguments: [
    "", "not json", #"{"outcome":"vanished"}"#, #"{"outcome":"posted","accountID":"1"}"#,
    #"{"outcome":"failed","reason":"newReason","detail":"x"}"#,
  ])
  func anUnreadableResultIsAFailure(json: String) async throws {
    let stub = RunnerStub([output(json)])
    let publisher = try chromiumPublisher(
      environment: environment, runner: stub.runner, log: testLog)

    let error = await #expect(throws: Failure.self) { try await publisher(Request(message: "hi")) }

    #expect(error?.description.hasPrefix("helper returned an unreadable result") == true)
  }

  @Test func aCheckAnswerToAPostIsAFailure() async throws {
    let json =
      #"{"outcome":"checked","accountID":"442174011","sessionSource":"state","stateSaved":false}"#
    let stub = RunnerStub([output(json)])
    let publisher = try chromiumPublisher(
      environment: environment, runner: stub.runner, log: testLog)

    await #expect(throws: Failure.self) { try await publisher(Request(message: "hi")) }
  }

  @Test func checkAsksForACheckAndDescribesTheOutcome() async throws {
    let json =
      #"{"outcome":"checked","accountID":"442174011","sessionSource":"password","stateSaved":true}"#
    let stub = RunnerStub([output(json)])

    let summary = try await chromiumCheck(
      environment: environment, runner: stub.runner, log: testLog)

    #expect(try stub.request()["op"] as? String == "check")
    #expect(try stub.request()["text"] == nil)
    #expect(
      summary
        == "X account 442174011 verified via password session; composer opened; session state saved"
    )
  }

  @Test func aPostedAnswerToACheckIsAFailure() async throws {
    let stub = RunnerStub([output(posted)])

    await #expect(throws: Failure.self) {
      _ = try await chromiumCheck(environment: environment, runner: stub.runner, log: testLog)
    }
  }
}
