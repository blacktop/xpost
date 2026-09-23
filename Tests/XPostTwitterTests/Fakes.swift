import CryptoKit
import Foundation
import LocalAuthentication
import Synchronization
import XPostCore

@testable import XPostTwitter

/// A software P-256 key in place of the Secure Enclave. The blob is the raw private key.
struct InMemorySigner: PasskeySigner {
  func generateKey() throws -> GeneratedKey {
    let key = P256.Signing.PrivateKey()
    return GeneratedKey(
      publicKey: key.publicKey.rawRepresentation,
      publicKeyDER: key.publicKey.derRepresentation,
      keyBlob: key.rawRepresentation)
  }

  func signature(for data: Data, keyBlob: Data, context: LAContext?) throws -> Data {
    try P256.Signing.PrivateKey(rawRepresentation: keyBlob).signature(for: data)
      .derRepresentation
  }
}

/// Records the reasons it was asked for and never prompts.
final class RecordingPresence: PresenceCheck, Sendable {
  private let reasons = Mutex<[String]>([])

  var confirmed: [String] { reasons.withLock { $0 } }

  func confirm(reason: String) async throws -> LAContext? {
    reasons.withLock { $0.append(reason) }
    return nil
  }
}

func temporaryStore() -> PasskeyStore {
  PasskeyStore(
    url: FileManager.default.temporaryDirectory
      .appending(path: "xpost-tests-\(UUID().uuidString)/twitter-passkey.json"))
}

let testLog = RunLog(category: "test", isVerbose: false)

func decodeBase64URL(_ value: Any?) throws -> Data {
  guard let string = value as? String, let data = Data(base64URL: string) else {
    throw Failure("not a base64url string: \(String(describing: value))")
  }
  return data
}
