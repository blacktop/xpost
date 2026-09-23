import Foundation
import Testing
import XPostCore

@testable import XPostTwitter

@Suite struct SessionExportTests {
  private func cookie(
    _ name: String, _ value: String, domain: String = ".x.com", path: String = "/",
    expires: Date? = nil, sameSite: String = "Lax"
  ) throws -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE",
      .sameSitePolicy: sameSite,
      HTTPCookiePropertyKey("HttpOnly"): "TRUE",
    ]
    if let expires { properties[.expires] = expires }
    return try #require(HTTPCookie(properties: properties))
  }

  private func signedInCookies() throws -> [HTTPCookie] {
    try [cookie("auth_token", "fixture-token"), cookie("twid", "u%3D123")]
  }

  @Test func exportsOnlyApplicableCookiesInPlaywrightFormat() throws {
    let expires = Date().addingTimeInterval(3600)
    let cookies =
      try signedInCookies() + [
        cookie("ct0", "fixture-csrf", expires: expires, sameSite: "None"),
        cookie("strict", "value", sameSite: "Strict"),
        cookie("other", "private", domain: ".other.example"),
        cookie("wrong-path", "private", path: "/settings"),
        cookie("expired", "old", expires: Date(timeIntervalSince1970: 1)),
      ]
    let session = try ExportedSession(cookies: cookies, accountID: "123")
    let decoded = try JSONDecoder().decode(
      ExportedSession.self, from: JSONEncoder().encode(session))
    #expect(decoded.cookies.map(\.name) == ["auth_token", "twid", "ct0", "strict"])
    #expect(decoded.cookies[0].expires == -1)
    #expect(decoded.cookies[0].domain == ".x.com")
    #expect(decoded.cookies[0].path == "/")
    #expect(decoded.cookies[0].secure)
    #expect(decoded.cookies[0].httpOnly)
    #expect(decoded.cookies.map(\.sameSite) == ["Lax", "Lax", "None", "Strict"])
    #expect(abs(decoded.cookies[2].expires - expires.timeIntervalSince1970) < 1)
    #expect(decoded.origins.isEmpty)
  }

  @Test(arguments: ["", "１２３", "wrong", "999"])
  func refusesAnInvalidOrDifferentAccount(accountID: String) throws {
    #expect(throws: Failure.self) {
      try ExportedSession(cookies: signedInCookies(), accountID: accountID)
    }
  }

  @Test func requiresAuthenticationAndAnUnambiguousIdentity() throws {
    #expect(throws: Failure.self) {
      try ExportedSession(cookies: [cookie("twid", "u%3D123")], accountID: "123")
    }
    #expect(throws: Failure.self) {
      try ExportedSession(cookies: [cookie("auth_token", "token")], accountID: "123")
    }
    #expect(throws: Failure.self) {
      try ExportedSession(
        cookies: signedInCookies() + [cookie("twid", "u%3D999", domain: "x.com")], accountID: "123")
    }
  }

  @Test func writesPrivatelyAndNeverReplacesAnExistingFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appending(path: "state.json")
    let session = try ExportedSession(cookies: signedInCookies(), accountID: "123")
    try session.write(to: output)
    let original = try Data(contentsOf: output)
    #expect(
      try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int
        == 0o600)
    #expect(try JSONDecoder().decode(ExportedSession.self, from: original).cookies.count == 2)
    #expect(throws: Failure.self) { try session.write(to: output) }
    #expect(try Data(contentsOf: output) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
  }

  @Test func refusesSymlinksAndCleansUpFailedExports() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appending(path: "state.json")
    let target = directory.appending(path: "unrelated")
    try FileManager.default.createSymbolicLink(at: output, withDestinationURL: target)
    let session = try ExportedSession(cookies: signedInCookies(), accountID: "123")
    #expect(throws: Failure.self) { try session.write(to: output) }
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])
  }
}
