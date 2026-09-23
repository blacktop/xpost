// Software WebAuthn authenticator.
//
// WKWebView only exposes system passkeys to apps holding Apple's browser entitlement, so
// xpost answers X's WebAuthn ceremonies itself, with a key the signer provides.

import CryptoKit
import Foundation
import LocalAuthentication
import XPostCore

struct StoredCredential: Codable, Sendable, Equatable {
  let credentialID: Data
  let userHandle: Data
  let rpID: String
  /// Opaque handle that only the signer that made it can use.
  let keyBlob: Data
}

@MainActor
final class Authenticator {
  private let store: PasskeyStore
  private let signer: any PasskeySigner
  private let presence: any PresenceCheck
  private let log: RunLog
  private(set) var credential: StoredCredential?
  /// The passkey the current one replaced. X may still only know this one, if the
  /// registration that made the current one was cancelled or rejected.
  private(set) var previous: StoredCredential?

  init(
    store: PasskeyStore, credential: StoredCredential?, previous: StoredCredential?,
    signer: any PasskeySigner, presence: any PresenceCheck, log: RunLog
  ) {
    self.store = store
    self.credential = credential
    self.previous = previous
    self.signer = signer
    self.presence = presence
    self.log = log
  }

  /// Handles `navigator.credentials.create`: makes a new key and saves it.
  func register(rpID: String, origin: String, challenge: Data, userHandle: Data) async throws
    -> [String: Any]
  {
    _ = try await presence.confirm(reason: "create a passkey for \(rpID)")

    let key = try signer.generateKey()
    let credentialID = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    let attested = try WebAuthn.attestedCredentialData(
      credentialID: credentialID, publicKey: key.publicKey)
    let authData = WebAuthn.authenticatorData(
      rpID: rpID, flags: WebAuthn.flagsAttestation, attested: attested)
    let clientData = WebAuthn.clientDataJSON(
      type: "webauthn.create", challenge: challenge, origin: origin)

    let stored = StoredCredential(
      credentialID: credentialID, userHandle: userHandle, rpID: rpID, keyBlob: key.keyBlob)
    try store.save(stored)
    if previous == nil {
      previous = credential
    }
    credential = stored

    return [
      "id": credentialID.base64URL,
      "clientDataJSON": clientData.base64URL,
      "attestationObject": try WebAuthn.attestationObject(authData: authData).base64URL,
      "authenticatorData": authData.base64URL,
      "publicKey": key.publicKeyDER.base64URL,
    ]
  }

  /// Handles `navigator.credentials.get`: signs the challenge once the user is present.
  ///
  /// X's allow list says which passkeys it accepted. When it names only the previous one
  /// for the same account, the newer registration never took, so the previous passkey is
  /// used and made current. A previous passkey for another account is never used: an allow
  /// list from that account's sign-in says nothing about the current one.
  func assertion(rpID: String, origin: String, challenge: Data, allowed: [Data]) async throws
    -> [String: Any]
  {
    guard let current = credential else {
      throw Failure("no passkey enrolled; run `xpost twitter enroll`")
    }
    let candidates = [current, previous].compactMap(\.self).filter {
      $0.rpID == rpID && $0.userHandle == current.userHandle
    }
    guard !candidates.isEmpty else {
      throw Failure("passkey is for \(current.rpID), not \(rpID)")
    }
    guard
      let credential = allowed.isEmpty
        ? candidates.first : candidates.first(where: { allowed.contains($0.credentialID) })
    else {
      throw Failure("X did not offer the xpost passkey; run `xpost twitter enroll` again")
    }
    if credential.credentialID == previous?.credentialID {
      log.note("X offered only the previous passkey; the newer one was never accepted")
      // The backup slot is taken, so save does not move the rejected key into it.
      try store.save(credential)
      try store.clearPrevious()
      self.credential = credential
      previous = nil
    } else if previous != nil, allowed.contains(credential.credentialID) {
      log.note("X accepted the current passkey; forgetting the previous one")
      try store.clearPrevious()
      previous = nil
    }

    let context = try await presence.confirm(reason: "sign in to \(rpID)")
    let authData = WebAuthn.authenticatorData(rpID: rpID, flags: WebAuthn.flagsAssertion)
    let clientData = WebAuthn.clientDataJSON(
      type: "webauthn.get", challenge: challenge, origin: origin)
    let signature = try signer.signature(
      for: authData + Data(SHA256.hash(data: clientData)), keyBlob: credential.keyBlob,
      context: context)

    return [
      "id": credential.credentialID.base64URL,
      "clientDataJSON": clientData.base64URL,
      "authenticatorData": authData.base64URL,
      "signature": signature.base64URL,
      "userHandle": credential.userHandle.base64URL,
    ]
  }
}
