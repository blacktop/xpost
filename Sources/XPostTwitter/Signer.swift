import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import XPostCore

struct GeneratedKey {
  /// The uncompressed P-256 point without the 0x04 prefix: x || y.
  let publicKey: Data
  /// SubjectPublicKeyInfo, what the page's `getPublicKey()` returns.
  let publicKeyDER: Data
  /// Whatever the signer needs to use the key again; opaque to everyone else.
  let keyBlob: Data
}

/// Makes and uses the ES256 keys behind the passkey.
protocol PasskeySigner: Sendable {
  func generateKey() throws -> GeneratedKey

  /// A DER-encoded ECDSA signature over `data`. `context` carries a user-presence check
  /// that already passed, when the key demands one.
  func signature(for data: Data, keyBlob: Data, context: LAContext?) throws -> Data
}

/// Confirms the user is present before a key is made or used. Main actor only, because
/// `LAContext` is not `Sendable` and the prompt belongs to the app's front window anyway.
protocol PresenceCheck {
  /// The context the check ran in, so signing does not prompt again; nil when none is needed.
  @MainActor func confirm(reason: String) async throws -> LAContext?
}

/// The private key never leaves the Secure Enclave and every signature needs Touch ID (or
/// the login password).
struct SecureEnclaveSigner: PasskeySigner {
  func generateKey() throws -> GeneratedKey {
    guard SecureEnclave.isAvailable else {
      throw Failure("this Mac has no Secure Enclave")
    }
    let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: try accessControl())
    return GeneratedKey(
      publicKey: key.publicKey.rawRepresentation,
      publicKeyDER: key.publicKey.derRepresentation,
      keyBlob: key.dataRepresentation)
  }

  func signature(for data: Data, keyBlob: Data, context: LAContext?) throws -> Data {
    let key = try SecureEnclave.P256.Signing.PrivateKey(
      dataRepresentation: keyBlob, authenticationContext: context)
    return try key.signature(for: data).derRepresentation
  }

  private func accessControl() throws -> SecAccessControl {
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        [.privateKeyUsage, .userPresence], &error)
    else {
      let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
      throw Failure("cannot create key access control: \(reason)")
    }
    return access
  }
}

/// Touch ID, or the login password as macOS's fallback.
struct TouchIDPresence: PresenceCheck {
  private static let timeout: TimeInterval = 60

  let log: RunLog

  /// The Touch ID sheet only appears for the frontmost app, so activate first.
  @MainActor
  func confirm(reason: String) async throws -> LAContext? {
    let context = LAContext()
    var policyError: NSError?
    let available = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError)
    log.note("presence check: available=\(available) biometry=\(context.biometryType.rawValue)")
    guard available else {
      let reason = policyError?.localizedDescription ?? "unknown reason"
      throw Failure("macOS cannot verify user presence: \(reason)")
    }

    NSApp.activate(ignoringOtherApps: true)
    // A prompt that macOS fails to present never calls back; invalidating ends the wait.
    let timeout = DispatchWorkItem { context.invalidate() }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)
    defer { timeout.cancel() }

    log.note("waiting for Touch ID or password approval")
    do {
      try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    } catch {
      throw Failure("user presence check failed: \(error)")
    }
    log.note("presence confirmed")
    return context
  }
}
