// The WebAuthn byte formats X receives, built by hand so the bytes that get hashed and
// signed are exactly the bytes sent.

import CryptoKit
import Foundation
import XPostCore

enum WebAuthn {
  static let flagsAssertion: UInt8 = 0x05  // user present + user verified
  static let flagsAttestation: UInt8 = 0x45  // ... + attested credential data

  /// rpIdHash || flags || counter || attested credential data.
  static func authenticatorData(rpID: String, flags: UInt8, attested: Data = Data()) -> Data {
    var data = Data(SHA256.hash(data: Data(rpID.utf8)))
    data.append(flags)
    data.append(contentsOf: [0, 0, 0, 0])  // signature counter: unsupported, always zero
    data.append(attested)
    return data
  }

  /// AAGUID (all zero, no authenticator model claimed) || credential ID || COSE key.
  static func attestedCredentialData(credentialID: Data, publicKey: Data) throws -> Data {
    guard credentialID.count == 32 else {
      throw Failure("unexpected credential ID size \(credentialID.count)")
    }
    guard publicKey.count == 64 else {
      throw Failure("unexpected public key size \(publicKey.count)")
    }
    var attested = Data(count: 16)
    attested.append(contentsOf: [0x00, 0x20])  // credential ID length
    attested.append(credentialID)
    attested.append(coseKey(x: publicKey.prefix(32), y: publicKey.suffix(32)))
    return attested
  }

  static func clientDataJSON(type: String, challenge: Data, origin: String) -> Data {
    let json =
      "{\"type\":\"\(type)\",\"challenge\":\"\(challenge.base64URL)\","
      + "\"origin\":\"\(origin)\",\"crossOrigin\":false}"
    return Data(json.utf8)
  }

  /// COSE_Key for ES256: {1: 2 (EC2), 3: -7 (ES256), -1: 1 (P-256), -2: x, -3: y}.
  static func coseKey(x: Data, y: Data) -> Data {
    var key = Data([0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20])
    key.append(x)
    key.append(contentsOf: [0x22, 0x58, 0x20])
    key.append(y)
    return key
  }

  /// CBOR map {"fmt": "none", "attStmt": {}, "authData": bytes}.
  static func attestationObject(authData: Data) throws -> Data {
    guard (24..<256).contains(authData.count) else {
      throw Failure("unexpected authenticator data size \(authData.count)")
    }
    var object = Data([0xA3])
    object.append(cborText("fmt"))
    object.append(cborText("none"))
    object.append(cborText("attStmt"))
    object.append(0xA0)
    object.append(cborText("authData"))
    object.append(contentsOf: [0x58, UInt8(authData.count)])
    object.append(authData)
    return object
  }

  /// Only valid for strings shorter than 24 bytes, which covers the fixed keys above.
  private static func cborText(_ text: String) -> Data {
    Data([0x60 | UInt8(text.utf8.count)]) + Data(text.utf8)
  }

  /// The origin a page may use credentials for `rpID` from: https on the RP's host or a
  /// subdomain of it. The protocol and host must come from WebKit, not from the page.
  static func origin(protocol: String, host: String, rpID: String) throws -> String {
    guard `protocol` == "https", host == rpID || host.hasSuffix(".\(rpID)") else {
      throw Failure("\(host) may not use credentials for \(rpID)")
    }
    return "https://\(host)"
  }
}

extension Data {
  var base64URL: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  init?(base64URL string: String) {
    var padded =
      string
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
    self.init(base64Encoded: padded)
  }
}
