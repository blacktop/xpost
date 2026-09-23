import Foundation
import Testing
import XPostCore

@testable import XPostTwitter

@Suite struct PasskeyStoreTests {
  private let store = temporaryStore()
  private let credential = StoredCredential(
    credentialID: Data(repeating: 1, count: 32), userHandle: Data([2]), rpID: "x.com",
    keyBlob: Data([3, 4, 5]))

  @Test func loadsNilBeforeAnythingIsSaved() throws {
    #expect(try store.load() == nil)
  }

  @Test func roundTripsWithOwnerOnlyPermissions() throws {
    try store.save(credential)

    #expect(try store.load() == credential)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    let directory = try FileManager.default.attributesOfItem(
      atPath: store.url.deletingLastPathComponent().path)
    #expect(directory[.posixPermissions] as? Int == 0o700)
  }

  @Test func stagesPrivatePermissionsBeforePublishingInATraversableDirectory() throws {
    let directory = store.url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    defer { try? FileManager.default.removeItem(at: directory) }

    let staged = try store.stage(credential)

    let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    #expect(
      try JSONDecoder().decode(StoredCredential.self, from: Data(contentsOf: staged)) == credential)
    #expect(!FileManager.default.fileExists(atPath: store.url.path))
    try FileManager.default.removeItem(at: staged)

    try store.save(credential)
    #expect(try store.load() == credential)
    #expect(
      try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        == 0o600)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path) == [
        store.url.lastPathComponent
      ])
  }

  @Test func keepsTheReplacedPasskeyUntilItIsCleared() throws {
    try store.save(credential)
    #expect(try store.loadPrevious() == nil)
    let replacement = StoredCredential(
      credentialID: Data(repeating: 9, count: 32), userHandle: Data([2]), rpID: "x.com",
      keyBlob: Data([6]))

    try store.save(replacement)
    #expect(try store.load() == replacement)
    #expect(try store.loadPrevious() == credential)
    for file in [store.url, store.previousURL] {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    try store.clearPrevious()
    #expect(try store.loadPrevious() == nil)
    #expect(try store.load() == replacement)
    try store.clearPrevious()
  }

  // Attempt after attempt must not push the last key that worked out of the backup slot.
  @Test func keepsTheOldestUnconfirmedReplacementAsThePrevious() throws {
    try store.save(credential)
    let second = StoredCredential(
      credentialID: Data(repeating: 2, count: 32), userHandle: Data([2]), rpID: "x.com",
      keyBlob: Data([2]))
    let third = StoredCredential(
      credentialID: Data(repeating: 3, count: 32), userHandle: Data([2]), rpID: "x.com",
      keyBlob: Data([3]))

    try store.save(second)
    try store.save(third)

    #expect(try store.load() == third)
    #expect(try store.loadPrevious() == credential)
  }

  @Test func reportsAMalformedFileWithItsPath() throws {
    try FileManager.default.createDirectory(
      at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("nope".utf8).write(to: store.url)

    let error = #expect(throws: Failure.self) { try store.load() }
    #expect(error?.description.contains(store.url.path) == true)
    #expect(error?.description.hasSuffix("delete it and enroll again") == true)
  }
}

@Suite struct SessionStoreTests {
  private func identity(_ value: String, domain: String = ".x.com", path: String = "/") throws
    -> HTTPCookie
  {
    try #require(
      HTTPCookie(properties: [.name: "twid", .value: value, .domain: domain, .path: path]))
  }

  @Test(arguments: ["notx.com", ".notx.com", "api.x.com", ".twitter.com"])
  func unrelatedDomainsCannotVouchForTheComposer(domain: String) throws {
    #expect(signedInUserID(in: [try identity("u%3D442174011", domain: domain)]) == nil)
  }

  @Test(arguments: ["/settings", "/compose/other", "/compose/pos", "/compose/post/child"])
  func unrelatedPathsCannotVouchForTheComposer(path: String) throws {
    #expect(signedInUserID(in: [try identity("u%3D442174011", path: path)]) == nil)
  }

  @Test(arguments: ["/", "/compose", "/compose/", "/compose/post"])
  func applicablePathsAndDuplicateIdentitiesAreAccepted(path: String) throws {
    #expect(
      signedInUserID(in: [
        try identity("u%3D442174011"), try identity("u%3D442174011", domain: "x.com", path: path),
      ]) == "442174011")
  }

  @Test func conflictingApplicableIdentitiesFailInEitherOrder() throws {
    let cookies = [try identity("u%3D442174011"), try identity("u%3D999", path: "/compose")]
    #expect(signedInUserID(in: cookies) == nil)
    #expect(signedInUserID(in: cookies.reversed()) == nil)
  }

  @Test func malformedApplicableIdentityCannotHideBehindAValidOne() throws {
    #expect(
      signedInUserID(in: [try identity("u%3D442174011"), try identity("u%ZZ", path: "/compose")])
        == nil)
  }

  @Test func expiredIdentityDoesNotConflict() throws {
    let expired = try #require(
      HTTPCookie(properties: [
        .name: "twid", .value: "u%3D999", .domain: ".x.com", .path: "/",
        .expires: Date(timeIntervalSince1970: 1),
      ]))
    #expect(signedInUserID(in: [expired, try identity("u%3D442174011")]) == "442174011")
  }

  @Test func encodesAndDecodesTheAccountAndItsCookies() throws {
    let expires = Date(timeIntervalSince1970: 1_800_000_000)
    let cookies = try [
      #require(
        HTTPCookie(properties: [
          .name: "auth_token", .value: "secret", .domain: ".x.com", .path: "/",
          .secure: "TRUE", .expires: expires,
        ])),
      #require(
        HTTPCookie(properties: [.name: "ct0", .value: "csrf", .domain: "x.com", .path: "/"])),
    ]

    let decoded = try SessionStore.decode(
      try SessionStore.encode(SavedSession(userID: "442174011", cookies: cookies)))

    #expect(decoded.userID == "442174011")
    #expect(decoded.cookies.map(\.name) == ["auth_token", "ct0"])
    #expect(decoded.cookies.map(\.value) == ["secret", "csrf"])
    #expect(decoded.cookies.map(\.domain) == [".x.com", "x.com"])
    #expect(decoded.cookies[0].isSecure)
    #expect(decoded.cookies[0].expiresDate == expires)
    #expect(!decoded.cookies[1].isSecure)
  }

  @Test func encodesNoCookiesAsAnEmptyList() throws {
    let decoded = try SessionStore.decode(
      try SessionStore.encode(SavedSession(userID: "442174011", cookies: [])))

    #expect(decoded.cookies.isEmpty)
  }

  @Test(arguments: [
    Data(), Data("garbage".utf8), Data("<plist version=\"1.0\"><array/></plist>".utf8),
  ])
  func rejectsDataWithoutAnAccountAndCookies(data: Data) {
    let error = #expect(throws: Failure.self) { try SessionStore.decode(data) }
    #expect(error?.description == "saved session is malformed; run `xpost twitter logout`")
  }

  @Test func readsTheSignedInUserIDFromTheTwidCookie() throws {
    let cookies = try [
      #require(
        HTTPCookie(properties: [.name: "ct0", .value: "csrf", .domain: ".x.com", .path: "/"])),
      #require(
        HTTPCookie(properties: [
          .name: "twid", .value: "u%3D442174011", .domain: ".x.com", .path: "/",
        ])),
    ]

    #expect(signedInUserID(in: cookies) == "442174011")
    #expect(signedInUserID(in: Array(cookies.prefix(1))) == nil)
  }

  @Test(arguments: ["", "u%3D", "442174011", "x%3D1"])
  func ignoresATwidCookieWithoutAUserID(value: String) throws {
    let twid = try #require(
      HTTPCookie(properties: [.name: "twid", .value: value, .domain: ".x.com", .path: "/"]))

    #expect(signedInUserID(in: [twid]) == nil)
  }
}

@Suite struct TwitterConfigTests {
  private let store = temporaryStore()

  private func enroll() throws {
    try store.save(
      StoredCredential(
        credentialID: Data(count: 32), userHandle: Data(), rpID: "x.com", keyBlob: Data()))
  }

  @Test func needsBothTheUserAndAPasskey() throws {
    try enroll()

    let config = try TwitterConfig(
      environment: ["XPOST_TWITTER_USER": " blacktop \n"], store: store)

    #expect(config.user == "blacktop")
  }

  @Test func namesWhatIsMissing() throws {
    #expect(
      throws: NotConfigured(
        target: .twitter, missing: ["XPOST_TWITTER_USER"],
        hint: "no passkey enrolled, run `xpost twitter enroll`")
    ) { try TwitterConfig(environment: [:], store: store) }

    #expect(
      throws: NotConfigured(
        target: .twitter, missing: [], hint: "no passkey enrolled, run `xpost twitter enroll`")
    ) { try TwitterConfig(environment: ["XPOST_TWITTER_USER": "blacktop"], store: store) }

    try enroll()
    #expect(throws: NotConfigured(target: .twitter, missing: ["XPOST_TWITTER_USER"])) {
      try TwitterConfig(environment: ["XPOST_TWITTER_USER": "  "], store: store)
    }
  }

  @Test func surfacesAnUnreadablePasskeyFile() throws {
    try FileManager.default.createDirectory(
      at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("nope".utf8).write(to: store.url)

    #expect(throws: Failure.self) {
      try TwitterConfig(environment: ["XPOST_TWITTER_USER": "blacktop"], store: store)
    }
  }
}
