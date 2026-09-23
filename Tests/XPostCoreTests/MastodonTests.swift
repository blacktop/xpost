import Foundation
import Testing

@testable import XPostCore

@Suite struct MastodonConfigTests {
  @Test func trimsSettings() throws {
    let config = try MastodonConfig(environment: [
      "XPOST_MASTODON_SERVER": " https://mastodon.example ",
      "XPOST_MASTODON_ACCESS_TOKEN": "tok\n",
    ])

    #expect(config.server.absoluteString == "https://mastodon.example")
    #expect(config.accessToken == "tok")
  }

  @Test func namesEveryMissingCredential() {
    #expect(
      throws: NotConfigured(
        target: .mastodon, missing: ["XPOST_MASTODON_SERVER", "XPOST_MASTODON_ACCESS_TOKEN"])
    ) { try MastodonConfig(environment: [:]) }
    #expect(throws: NotConfigured(target: .mastodon, missing: ["XPOST_MASTODON_ACCESS_TOKEN"])) {
      try MastodonConfig(environment: ["XPOST_MASTODON_SERVER": "https://mastodon.example"])
    }
  }

  @Test func rejectsAServerThatIsNotAnHTTPURL() {
    #expect(throws: InvalidSetting.self) {
      try MastodonConfig(environment: [
        "XPOST_MASTODON_SERVER": "mastodon.example", "XPOST_MASTODON_ACCESS_TOKEN": "tok",
      ])
    }
  }
}

@Suite struct MastodonClientTests {
  private let posted = #"{"id":"1","uri":"https://mastodon.example/@me/1"}"#
  private let attachment = #"{"id":"m1","type":"image","url":null}"#

  /// A client that answers from `stub`, or through `transport` when a test wraps it.
  private func client(
    _ stub: TransportStub, transport: Transport? = nil,
    mediaProcessingTimeout: Duration = .seconds(30), mediaPollInterval: Duration = .zero,
    retryDelay: Duration = .zero
  ) throws -> MastodonClient {
    MastodonClient(
      config: try MastodonConfig(environment: [
        "XPOST_MASTODON_SERVER": "https://mastodon.example", "XPOST_MASTODON_ACCESS_TOKEN": "tok",
      ]),
      transport: transport ?? stub.transport, log: testLog,
      mediaProcessingTimeout: mediaProcessingTimeout, mediaPollInterval: mediaPollInterval,
      retryDelay: retryDelay)
  }

  @Test func postsTheStatusAsJSON() async throws {
    let stub = TransportStub([.status(200, posted)])

    try await client(stub).publish(Request(message: "hi", link: "https://example.com"))

    let sent = try #require(stub.sent.first)
    #expect(stub.sent.count == 1)
    #expect(sent.path == "/api/v1/statuses")
    #expect(sent.request.httpMethod == "POST")
    #expect(sent.header("Content-Type") == "application/json")
    #expect(sent.header("Authorization") == "Bearer tok")
    #expect(try sent.json() == ["status": "hi\n\nhttps://example.com"])
    #expect(UUID(uuidString: sent.header("Idempotency-Key") ?? "") != nil)
  }

  @Test func uploadsTheImageThenAttachesIt() async throws {
    let image = try temporaryImage()
    defer { try? FileManager.default.removeItem(at: image) }
    let stub = TransportStub([.status(200, attachment), .status(200, posted)])

    try await client(stub).publish(
      Request(message: "hi", imagePath: image.path, imageAlt: "a chart"))

    let upload = stub.sent[0]
    #expect(upload.path == "/api/v2/media")
    #expect(upload.header("Authorization") == "Bearer tok")
    let contentType = try #require(upload.header("Content-Type"))
    let boundary = try #require(
      contentType.wholeMatch(of: /multipart\/form-data; boundary=(.+)/)?.1)
    #expect(
      upload.body
        == MultipartForm(
          fields: [("description", "a chart")],
          file: .init(
            name: "file", filename: image.lastPathComponent, mimeType: "image/png",
            data: Data([1, 2, 3])),
          boundary: String(boundary)
        ).body)

    #expect(try stub.sent[1].json() == ["status": "hi", "media_ids": ["m1"]])
  }

  @Test func waitsForMediaProcessingBeforePosting() async throws {
    let image = try temporaryImage()
    defer { try? FileManager.default.removeItem(at: image) }
    let stub = TransportStub([
      .status(202, attachment), .status(206, ""), .status(200, attachment), .status(200, posted),
    ])

    try await client(stub).publish(Request(message: "hi", imagePath: image.path))

    #expect(
      stub.sent.map(\.path) == [
        "/api/v2/media", "/api/v1/media/m1", "/api/v1/media/m1", "/api/v1/statuses",
      ])
    #expect(stub.sent.map(\.request.httpMethod) == ["POST", "GET", "GET", "POST"])
    for poll in stub.sent[1...2] {
      #expect(poll.header("Authorization") == "Bearer tok")
      #expect(poll.body == nil)
    }
    #expect(try stub.sent[3].json() == ["status": "hi", "media_ids": ["m1"]])
  }

  @Test(arguments: [204, 422, 500])
  func doesNotPostOrRetryWhenMediaProcessingFails(status: Int) async throws {
    let image = try temporaryImage()
    defer { try? FileManager.default.removeItem(at: image) }
    let stub = TransportStub([
      .status(202, attachment), .status(status, #"{"error":"processing failed"}"#),
    ])

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi", imagePath: image.path))
    }

    #expect(error?.description == "process media: HTTP \(status): processing failed")
    #expect(stub.sent.map(\.path) == ["/api/v2/media", "/api/v1/media/m1"])
  }

  @Test(arguments: [false, true])
  func boundsMediaProcessingEvenWhenARequestStalls(stallsRequest: Bool) async throws {
    let image = try temporaryImage()
    defer { try? FileManager.default.removeItem(at: image) }
    let stub = TransportStub([.status(202, attachment), .status(206, "")])
    let client = try self.client(
      stub,
      transport: { request, body in
        let reply = try await stub.transport(request, body)
        if stallsRequest, request.httpMethod == "GET" {
          try await Task.sleep(for: .seconds(60))
        }
        return reply
      },
      mediaProcessingTimeout: .milliseconds(100), mediaPollInterval: .seconds(1))
    let started = ContinuousClock.now

    let error = await #expect(throws: StepError.self) {
      try await client.publish(Request(message: "hi", imagePath: image.path))
    }

    #expect(error?.description == "process media: media processing timed out")
    #expect(ContinuousClock.now - started < .seconds(2))
    #expect(stub.sent.map(\.path) == ["/api/v2/media", "/api/v1/media/m1"])
  }

  @Test(arguments: [200, 206])
  func cancellationWhileProcessingPreventsThePost(status: Int) async throws {
    let image = try temporaryImage()
    defer { try? FileManager.default.removeItem(at: image) }
    let stub = TransportStub([.status(202, attachment), .status(status, attachment)])
    let client = try self.client(
      stub,
      transport: { request, body in
        let reply = try await stub.transport(request, body)
        if request.httpMethod == "GET" {
          withUnsafeCurrentTask { $0?.cancel() }
        }
        return reply
      })

    let error = await #expect(throws: StepError.self) {
      try await client.publish(Request(message: "hi", imagePath: image.path))
    }

    #expect(error?.step == "process media")
    #expect(error?.underlying is CancellationError)
    #expect(stub.sent.map(\.path) == ["/api/v2/media", "/api/v1/media/m1"])
  }

  @Test func omitsAnEmptyDescription() async throws {
    let image = try temporaryImage()
    defer { try? FileManager.default.removeItem(at: image) }
    let stub = TransportStub([.status(200, attachment), .status(200, posted)])

    try await client(stub).publish(Request(message: "hi", imagePath: image.path))

    let body = String(decoding: stub.sent[0].body ?? Data(), as: UTF8.self)
    #expect(!body.contains("description"))
  }

  @Test func anUnreadableImageStopsBeforeAnyRequest() async throws {
    let stub = TransportStub([])

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi", imagePath: "/nonexistent/x.png"))
    }
    #expect(error?.step == "read image")
    #expect(stub.sent.isEmpty)
  }

  // An upload has no idempotency key, so a retry could leave a second copy on the server.
  @Test(arguments: [
    (422, #"{"error":"File is too large"}"#, "upload media: HTTP 422: File is too large"),
    (503, "<html>gateway</html>", "upload media: HTTP 503"),
  ])
  func doesNotPostOrRetryWhenTheUploadFails(status: Int, body: String, message: String)
    async throws
  {
    let image = try temporaryImage()
    defer { try? FileManager.default.removeItem(at: image) }
    let stub = TransportStub([.status(status, body), .status(200, attachment)])

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi", imagePath: image.path))
    }

    #expect(error?.description == message)
    #expect(stub.sent.count == 1)
    #expect(stub.sent.first?.header("Idempotency-Key") == nil)
  }

  @Test(arguments: [502, 503, 504])
  func retriesAGatewayErrorWithTheSameIdempotencyKey(status: Int) async throws {
    let stub = TransportStub([.status(status, "<html>gateway</html>"), .status(200, posted)])

    try await client(stub).publish(Request(message: "hi"))

    #expect(stub.sent.map(\.path) == ["/api/v1/statuses", "/api/v1/statuses"])
    let key = try #require(stub.sent[0].header("Idempotency-Key"))
    #expect(stub.sent[1].header("Idempotency-Key") == key)
    #expect(stub.sent[1].body == stub.sent[0].body)
  }

  @Test func retriesANetworkFailure() async throws {
    let stub = TransportStub([
      .failure(NetworkFailure(description: "The network connection was lost.")),
      .status(200, posted),
    ])

    try await client(stub).publish(Request(message: "hi"))

    #expect(stub.sent.count == 2)
  }

  // Mastodon answered these itself, so asking again within seconds gets the same answer.
  @Test(arguments: [401, 422, 429, 500])
  func doesNotRetryAnErrorMastodonAnswered(status: Int) async throws {
    let stub = TransportStub([.status(status, #"{"error":"no"}"#), .status(200, posted)])

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi"))
    }

    #expect(error?.underlying as? HTTPStatusError == HTTPStatusError(status: status, detail: "no"))
    #expect(stub.sent.count == 1)
  }

  @Test func givesUpAfterThreeAttemptsAndSaysThePostMayHaveGoneOut() async throws {
    let stub = TransportStub(Array(repeating: .status(503, ""), count: 3))

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi"))
    }

    #expect(
      error?.description
        == "post status: HTTP 503 (3 attempts; the post may have gone out, check before rerunning)"
    )
    #expect(stub.sent.count == 3)
  }

  // A shared key would make Mastodon answer the second post with the first one.
  @Test func eachPublishHasItsOwnIdempotencyKey() async throws {
    let stub = TransportStub([.status(200, posted), .status(200, posted)])
    let client = try client(stub)

    try await client.publish(Request(message: "hi"))
    try await client.publish(Request(message: "hi"))

    let keys = stub.sent.compactMap { $0.header("Idempotency-Key") }
    #expect(keys.count == 2)
    #expect(Set(keys).count == 2)
  }

  @Test func waitsLongerBeforeEachRetry() async throws {
    let stub = TransportStub([.status(503, ""), .status(503, ""), .status(200, posted)])
    let client = try self.client(stub, retryDelay: .milliseconds(50))
    let started = ContinuousClock.now

    try await client.publish(Request(message: "hi"))

    #expect(ContinuousClock.now - started >= .milliseconds(150))
    #expect(stub.sent.count == 3)
  }

  @Test(arguments: 1...3)
  func cancellationOnAnyAttemptStopsRetrying(attempt: Int) async throws {
    let stub = TransportStub(
      Array(repeating: .status(503, ""), count: attempt) + [.status(200, posted)])
    let client = try self.client(
      stub,
      transport: { request, body in
        let reply = try await stub.transport(request, body)
        if stub.sent.count == attempt {
          withUnsafeCurrentTask { $0?.cancel() }
        }
        return reply
      })
    let publishing = Task { try await client.publish(Request(message: "hi")) }

    let error = await #expect(throws: StepError.self) { try await publishing.value }

    #expect(error?.step == "post status")
    #expect(error?.underlying is CancellationError)
    #expect(stub.sent.count == attempt)
  }

  @Test func includesTheErrorDescription() async throws {
    let stub = TransportStub([
      .status(401, #"{"error":"invalid_token","error_description":"The access token is invalid"}"#)
    ])

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi"))
    }

    #expect(
      error?.description == "post status: HTTP 401: invalid_token: The access token is invalid")
  }

  @Test func reportsANetworkFailureByStep() async throws {
    let stub = TransportStub(
      Array(repeating: .failure(NetworkFailure(description: "The request timed out.")), count: 3))

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi"))
    }

    #expect(
      error?.description
        == "post status: The request timed out. (3 attempts; the post may have gone out, "
        + "check before rerunning)")
  }

  @Test func reportsAMalformedSuccessBody() async throws {
    let stub = TransportStub([.status(200, "[]")])

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi"))
    }

    #expect(error?.description.hasPrefix("post status: unexpected response: ") == true)
  }
}

@Suite struct MastodonPublisherTests {
  @Test func isNotConfiguredWithoutCredentials() {
    #expect(throws: NotConfigured.self) {
      try mastodonPublisher(
        environment: [:], transport: TransportStub([]).transport,
        log: testLog)
    }
  }
}
