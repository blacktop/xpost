import Foundation
import Testing

@testable import XPostCore

@Suite struct BlueskyConfigTests {
  private let credentials = [
    "XPOST_BLUESKY_HANDLE": " me.example ", "XPOST_BLUESKY_APP_PASSWORD": "pass-word\n",
  ]

  @Test func trimsSettingsAndDefaultsThePDS() throws {
    let config = try BlueskyConfig(environment: credentials)

    #expect(config.handle == "me.example")
    #expect(config.appPassword == "pass-word")
    #expect(config.pdsURL.absoluteString == "https://bsky.social")
  }

  @Test func namesEveryMissingCredential() {
    #expect(
      throws: NotConfigured(
        target: .bluesky, missing: ["XPOST_BLUESKY_HANDLE", "XPOST_BLUESKY_APP_PASSWORD"])
    ) { try BlueskyConfig(environment: ["XPOST_BLUESKY_HANDLE": "  "]) }
    #expect(throws: NotConfigured(target: .bluesky, missing: ["XPOST_BLUESKY_APP_PASSWORD"])) {
      try BlueskyConfig(environment: ["XPOST_BLUESKY_HANDLE": "me.example"])
    }
  }

  @Test(arguments: [
    ("https://bsky.social", "https://bsky.social"),
    ("https://user:p%40ss@pds.example:8443/base", "https://pds.example:8443"),
    ("https://pds.example/private-token?token=secret#fragment", "https://pds.example"),
    ("http://user:pass@[::1]:8080/base?token=secret#fragment", "http://[::1]:8080"),
  ])
  func logsOnlyThePDSOrigin(pds: String, origin: String) throws {
    var environment = credentials
    environment["XPOST_BLUESKY_PDS_URL"] = pds
    let config = try BlueskyConfig(environment: environment)

    #expect(config.pdsLogOrigin == origin)
    #expect(config.pdsURL.absoluteString == pds)
  }

  @Test(arguments: ["pds.example", "ftp://pds.example", "https://"])
  func rejectsAPDSThatIsNotAnHTTPURL(pds: String) {
    var environment = credentials
    environment["XPOST_BLUESKY_PDS_URL"] = pds

    #expect(throws: InvalidSetting.self) { try BlueskyConfig(environment: environment) }
  }
}

@Suite struct BlueskyClientTests {
  private let session =
    #"{"accessJwt":"jwt-1","refreshJwt":"r","handle":"me.example","did":"did:plc:abc"}"#
  private let created = #"{"uri":"at://did:plc:abc/app.bsky.feed.post/1","cid":"bafy"}"#
  private let blob =
    #"{"blob":{"$type":"blob","ref":{"$link":"bafkrei"},"mimeType":"image/png","size":3}}"#

  private func client(_ stub: TransportStub, pds: String = "https://pds.example") throws
    -> BlueskyClient
  {
    BlueskyClient(
      config: try BlueskyConfig(environment: [
        "XPOST_BLUESKY_HANDLE": "me.example", "XPOST_BLUESKY_APP_PASSWORD": "app-pass",
        "XPOST_BLUESKY_PDS_URL": pds,
      ]),
      transport: stub.transport, log: testLog,
      now: { Date(timeIntervalSince1970: 1_790_000_000) })
  }

  @Test func logsInThenCreatesTheRecord() async throws {
    let stub = TransportStub([.status(200, session), .status(200, created)])

    try await client(stub).publish(
      Request(
        message: "🎉 see https://example.com/page.", link: "https://example.org/a/long/path/xyz"))

    let sent = stub.sent
    #expect(
      sent.map(\.path) == [
        "/xrpc/com.atproto.server.createSession", "/xrpc/com.atproto.repo.createRecord",
      ])
    #expect(sent.allSatisfy { $0.request.httpMethod == "POST" })
    #expect(sent.allSatisfy { $0.header("Content-Type") == "application/json" })

    #expect(sent[0].header("Authorization") == nil)
    #expect(try sent[0].json() == ["identifier": "me.example", "password": "app-pass"])

    #expect(sent[1].header("Authorization") == "Bearer jwt-1")
    let link = "app.bsky.richtext.facet#link"
    #expect(
      try sent[1].json() == [
        "repo": "did:plc:abc",
        "collection": "app.bsky.feed.post",
        "record": [
          "$type": "app.bsky.feed.post",
          "text": "🎉 see example.com/page.\n\nexample.org/a/long/path/...",
          "createdAt": "2026-09-21T14:13:20Z",
          "facets": [
            [
              "index": ["byteStart": 9, "byteEnd": 25],
              "features": [["$type": link, "uri": "https://example.com/page"]],
            ],
            [
              "index": ["byteStart": 28, "byteEnd": 55],
              "features": [["$type": link, "uri": "https://example.org/a/long/path/xyz"]],
            ],
          ],
        ],
      ])
  }

  @Test func omitsFacetsAndEmbedForPlainText() async throws {
    let stub = TransportStub([.status(200, session), .status(200, created)])

    try await client(stub).publish(Request(message: "plain"))

    let record = try #require(try stub.sent[1].json()["record"] as? NSDictionary)
    #expect(record["facets"] == nil)
    #expect(record["embed"] == nil)
  }

  @Test func keepsAPathPrefixOnThePDSURL() async throws {
    let stub = TransportStub([.status(200, session), .status(200, created)])

    try await client(stub, pds: "https://pds.example/base/").publish(Request(message: "hi"))

    #expect(stub.sent[0].path == "/base/xrpc/com.atproto.server.createSession")
  }

  @Test(arguments: [
    ("shot.png", "image/png"), ("photo.JPG", "image/jpeg"), ("blob", "application/octet-stream"),
  ])
  func uploadsTheImageWithItsRealTypeAndEmbedsTheBlob(name: String, mimeType: String) async throws {
    let image = try temporaryImage(named: name)
    defer { try? FileManager.default.removeItem(at: image) }
    let stub = TransportStub([.status(200, session), .status(200, blob), .status(200, created)])

    try await client(stub).publish(
      Request(message: "hi", imagePath: image.path, imageAlt: "a chart"))

    let upload = stub.sent[1]
    #expect(upload.path == "/xrpc/com.atproto.repo.uploadBlob")
    #expect(upload.header("Content-Type") == mimeType)
    #expect(upload.header("Authorization") == "Bearer jwt-1")
    #expect(upload.body == Data([1, 2, 3]))

    let record = try #require(try stub.sent[2].json()["record"] as? NSDictionary)
    #expect(
      record["embed"] as? NSDictionary == [
        "$type": "app.bsky.embed.images",
        "images": [
          [
            "alt": "a chart",
            "image": [
              "$type": "blob", "ref": ["$link": "bafkrei"], "mimeType": "image/png", "size": 3,
            ],
          ]
        ],
      ])
  }

  @Test func anUnreadableImageStopsBeforeUploadingOrPosting() async throws {
    let stub = TransportStub([.status(200, session)])

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi", imagePath: "/nonexistent/shot.png"))
    }
    #expect(error?.step == "read image")
    #expect(stub.sent.count == 1)
  }

  @Test func decodesTheXRPCErrorAndStopsAfterAFailedLogin() async throws {
    let stub = TransportStub([
      .status(
        401, #"{"error":"AuthenticationRequired","message":"Invalid identifier or password"}"#)
    ])

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi"))
    }

    #expect(
      error?.description
        == "login: HTTP 401: AuthenticationRequired: Invalid identifier or password")
    #expect(stub.sent.count == 1)
  }

  @Test func keepsTheStatusWhenTheErrorBodyIsNotXRPC() async throws {
    let stub = TransportStub([.status(200, session), .status(502, "<html>Bad Gateway</html>")])

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi"))
    }

    #expect(error?.step == "create record")
    #expect(error?.underlying as? HTTPStatusError == HTTPStatusError(status: 502, detail: ""))
    #expect(error?.description == "create record: HTTP 502")
  }

  @Test func doesNotPostWhenTheUploadFails() async throws {
    let image = try temporaryImage(named: "shot.png")
    defer { try? FileManager.default.removeItem(at: image) }
    let stub = TransportStub([
      .status(200, session), .status(400, #"{"error":"BlobTooLarge","message":"too big"}"#),
    ])

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi", imagePath: image.path))
    }

    #expect(error?.description == "upload blob: HTTP 400: BlobTooLarge: too big")
    #expect(stub.sent.count == 2)
  }

  @Test func reportsANetworkFailureByStep() async throws {
    let stub = TransportStub([
      .failure(NetworkFailure(description: "The Internet connection appears to be offline."))
    ])

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi"))
    }

    #expect(error?.description == "login: The Internet connection appears to be offline.")
  }

  @Test(arguments: ["{}", "not json", #"{"accessJwt":"jwt-1"}"#])
  func reportsAMalformedSuccessBody(body: String) async throws {
    let stub = TransportStub([.status(200, body)])

    let error = await #expect(throws: StepError.self) {
      try await client(stub).publish(Request(message: "hi"))
    }

    #expect(error?.description.hasPrefix("login: unexpected response: ") == true)
    #expect(stub.sent.count == 1)
  }
}

@Suite struct MediaTests {
  @Test(arguments: [
    ("png", "image/png"), ("PNG", "image/png"), ("jpg", "image/jpeg"), ("JPEG", "image/jpeg"),
    ("gif", "image/gif"), ("webp", "image/webp"), ("", "application/octet-stream"),
  ])
  func mapsImageExtensionsWithoutLaunchServices(ext: String, want: String) {
    #expect(imageMIMEType(forExtension: ext) == want)
  }
}

@Suite struct BlueskyPublisherTests {
  @Test func isNotConfiguredWithoutCredentials() {
    #expect(throws: NotConfigured.self) {
      try blueskyPublisher(
        environment: [:], transport: TransportStub([]).transport,
        log: testLog)
    }
  }
}
