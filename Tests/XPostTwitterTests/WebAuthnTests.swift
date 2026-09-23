import CryptoKit
import Foundation
import Testing
import XPostCore

@testable import XPostTwitter

@Suite struct WebAuthnTests {
  @Test func authenticatorDataIsHashFlagsCounterThenAttested() {
    let data = WebAuthn.authenticatorData(rpID: "x.com", flags: 0x05, attested: Data([9, 9]))

    #expect(data.count == 32 + 1 + 4 + 2)
    #expect(data.prefix(32) == Data(SHA256.hash(data: Data("x.com".utf8))))
    #expect(data[32] == 0x05)
    #expect(data[33..<37] == Data([0, 0, 0, 0]))
    #expect(data.suffix(2) == Data([9, 9]))
  }

  @Test func attestedCredentialDataCarriesTheCOSEKey() throws {
    let credentialID = Data(repeating: 0xCC, count: 32)
    let x = Data(repeating: 0xAA, count: 32)
    let y = Data(repeating: 0xBB, count: 32)

    let attested = try WebAuthn.attestedCredentialData(credentialID: credentialID, publicKey: x + y)

    #expect(attested.prefix(16) == Data(count: 16))
    #expect(attested[16..<18] == Data([0x00, 0x20]))
    #expect(attested[18..<50] == credentialID)
    // {1: 2, 3: -7, -1: 1, -2: x, -3: y}
    #expect(
      attested[50...]
        == Data([0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20]) + x
        + Data([0x22, 0x58, 0x20]) + y)
  }

  @Test func attestedCredentialDataRejectsWrongSizes() {
    #expect(throws: Failure.self) {
      try WebAuthn.attestedCredentialData(credentialID: Data(count: 16), publicKey: Data(count: 64))
    }
    #expect(throws: Failure.self) {
      try WebAuthn.attestedCredentialData(credentialID: Data(count: 32), publicKey: Data(count: 65))
    }
  }

  @Test func clientDataJSONHasTheFieldsInWebAuthnOrder() {
    let json = WebAuthn.clientDataJSON(
      type: "webauthn.get", challenge: Data([0xFB, 0xFF]), origin: "https://x.com")

    #expect(
      String(decoding: json, as: UTF8.self)
        == #"{"type":"webauthn.get","challenge":"-_8","origin":"https://x.com","crossOrigin":false}"#
    )
  }

  @Test func attestationObjectIsACBORMapAroundTheAuthData() throws {
    let authData = Data(repeating: 0xEE, count: 37)

    let object = try WebAuthn.attestationObject(authData: authData)

    var want = Data([0xA3])
    want += Data([0x63]) + Data("fmt".utf8)
    want += Data([0x64]) + Data("none".utf8)
    want += Data([0x67]) + Data("attStmt".utf8)
    want += Data([0xA0])
    want += Data([0x68]) + Data("authData".utf8)
    want += Data([0x58, 37]) + authData
    #expect(object == want)
  }

  @Test(arguments: [23, 256])
  func attestationObjectRejectsSizesOutsideOneByteLength(size: Int) {
    #expect(throws: Failure.self) {
      try WebAuthn.attestationObject(authData: Data(count: size))
    }
  }

  @Test(arguments: [
    ("https", "x.com", "x.com", "https://x.com"),
    ("https", "mobile.x.com", "x.com", "https://mobile.x.com"),
  ])
  func originAllowsTheRPAndItsSubdomainsOverHTTPS(
    scheme: String, host: String, rpID: String, want: String
  ) throws {
    #expect(try WebAuthn.origin(protocol: scheme, host: host, rpID: rpID) == want)
  }

  @Test(arguments: [
    ("http", "x.com", "x.com"),
    ("https", "evil.com", "x.com"),
    ("https", "notx.com", "x.com"),
    ("https", "x.com.evil.com", "x.com"),
    ("https", "x.com", "mobile.x.com"),
  ])
  func originRejectsOtherHostsAndPlainHTTP(scheme: String, host: String, rpID: String) {
    #expect(throws: Failure.self) {
      try WebAuthn.origin(protocol: scheme, host: host, rpID: rpID)
    }
  }

  @Test(arguments: [
    Data(), Data([0xFB]), Data([0xFB, 0xFF]), Data([0xFB, 0xFF, 0x3E]), Data(count: 33),
  ])
  func base64URLRoundTripsWithoutPadding(data: Data) {
    let encoded = data.base64URL

    #expect(!encoded.contains(where: { "+/=".contains($0) }))
    #expect(Data(base64URL: encoded) == data)
  }
}
