import CryptoKit
import Foundation
import Testing
import XPostCore

@testable import XPostTwitter

@Suite @MainActor struct AuthenticatorTests {
  private let store = temporaryStore()
  private let presence = RecordingPresence()
  private let challenge = Data((0..<32).map { UInt8($0) })

  private func authenticator() -> Authenticator {
    Authenticator(
      store: store, credential: nil, previous: nil, signer: InMemorySigner(),
      presence: presence, log: testLog)
  }

  /// Registers twice, so the first passkey is the previous one on disk and in memory.
  private func reenrolled() async throws -> (Authenticator, first: Data, second: Data) {
    let authenticator = authenticator()
    _ = try await authenticator.register(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, userHandle: Data([1]))
    let first = try #require(authenticator.credential?.credentialID)
    _ = try await authenticator.register(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, userHandle: Data([1]))
    let second = try #require(authenticator.credential?.credentialID)
    #expect(authenticator.previous?.credentialID == first)
    #expect(try store.loadPrevious()?.credentialID == first)
    return (authenticator, first, second)
  }

  @Test func fallsBackToThePreviousPasskeyWhenXOffersOnlyThat() async throws {
    let (authenticator, first, _) = try await reenrolled()

    let reply = try await authenticator.assertion(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, allowed: [first])

    #expect(try decodeBase64URL(reply["id"]) == first)
    #expect(authenticator.credential?.credentialID == first)
    #expect(authenticator.previous == nil)
    #expect(try store.load()?.credentialID == first)
    #expect(try store.loadPrevious() == nil)
  }

  @Test func forgetsThePreviousPasskeyOnceXAcceptsTheCurrentOne() async throws {
    let (authenticator, _, second) = try await reenrolled()

    _ = try await authenticator.assertion(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, allowed: [second])

    #expect(authenticator.credential?.credentialID == second)
    #expect(authenticator.previous == nil)
    #expect(try store.loadPrevious() == nil)
  }

  @Test func aThirdEnrollmentStillKeepsTheFirstPasskey() async throws {
    let (authenticator, first, _) = try await reenrolled()

    _ = try await authenticator.register(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, userHandle: Data([1]))

    #expect(authenticator.previous?.credentialID == first)
    #expect(try store.loadPrevious()?.credentialID == first)
  }

  @Test func neverFallsBackToAnotherAccountsPasskey() async throws {
    let authenticator = authenticator()
    _ = try await authenticator.register(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, userHandle: Data([1]))
    let accountA = try #require(authenticator.credential?.credentialID)
    _ = try await authenticator.register(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, userHandle: Data([2]))
    let accountB = try #require(authenticator.credential?.credentialID)

    // Account A's sign-in offers A's passkey; that says nothing about B's.
    await #expect(throws: Failure.self) {
      _ = try await authenticator.assertion(
        rpID: "x.com", origin: "https://x.com", challenge: challenge, allowed: [accountA])
    }

    #expect(authenticator.credential?.credentialID == accountB)
    #expect(authenticator.previous?.credentialID == accountA)
    #expect(try store.load()?.credentialID == accountB)
    #expect(try store.loadPrevious()?.credentialID == accountA)
    #expect(presence.confirmed.count == 2)
  }

  @Test func keepsThePreviousPasskeyWhileXHasNotNamedEither() async throws {
    let (authenticator, first, second) = try await reenrolled()

    let reply = try await authenticator.assertion(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, allowed: [])

    #expect(try decodeBase64URL(reply["id"]) == second)
    #expect(authenticator.previous?.credentialID == first)
    #expect(try store.loadPrevious()?.credentialID == first)
  }

  @Test func registrationSavesTheCredentialAndDescribesItsKey() async throws {
    let authenticator = authenticator()
    let userHandle = Data("user-1".utf8)

    let reply = try await authenticator.register(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, userHandle: userHandle)

    let stored = try #require(authenticator.credential)
    #expect(try store.load() == stored)
    #expect(stored.rpID == "x.com")
    #expect(stored.userHandle == userHandle)
    #expect(stored.credentialID.count == 32)
    #expect(try decodeBase64URL(reply["id"]) == stored.credentialID)
    #expect(presence.confirmed == ["create a passkey for x.com"])

    let clientData = try decodeBase64URL(reply["clientDataJSON"])
    #expect(
      String(decoding: clientData, as: UTF8.self).hasPrefix(
        #"{"type":"webauthn.create","challenge":"\#(challenge.base64URL)","origin":"https://x.com""#
      ))

    // The attestation object wraps the same authenticator data the reply also returns.
    let authData = try decodeBase64URL(reply["authenticatorData"])
    #expect(
      try decodeBase64URL(reply["attestationObject"])
        == WebAuthn.attestationObject(authData: authData))
    #expect(authData[32] == 0x45)
    #expect(authData[37..<53] == Data(count: 16))
    #expect(authData[55..<87] == stored.credentialID)

    // The COSE key in the attestation matches the DER public key in the reply.
    let cose = authData[87...]
    let point =
      cose[cose.startIndex + 10..<cose.startIndex + 42]
      + cose[cose.startIndex + 45..<cose.startIndex + 77]
    let fromCOSE = try P256.Signing.PublicKey(rawRepresentation: point)
    let fromDER = try P256.Signing.PublicKey(
      derRepresentation: try decodeBase64URL(reply["publicKey"]))
    #expect(fromCOSE.rawRepresentation == fromDER.rawRepresentation)
  }

  @Test func assertionSignatureVerifiesWithTheRegisteredKey() async throws {
    let authenticator = authenticator()
    let registration = try await authenticator.register(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, userHandle: Data([1]))
    let publicKey = try P256.Signing.PublicKey(
      derRepresentation: try decodeBase64URL(registration["publicKey"]))
    let loginChallenge = Data(repeating: 0x42, count: 32)

    let reply = try await authenticator.assertion(
      rpID: "x.com", origin: "https://mobile.x.com", challenge: loginChallenge, allowed: [])

    let authData = try decodeBase64URL(reply["authenticatorData"])
    let clientData = try decodeBase64URL(reply["clientDataJSON"])
    let signature = try P256.Signing.ECDSASignature(
      derRepresentation: try decodeBase64URL(reply["signature"]))
    #expect(
      publicKey.isValidSignature(signature, for: authData + Data(SHA256.hash(data: clientData))))

    #expect(authData.count == 37)
    #expect(authData[32] == 0x05)
    #expect(
      String(decoding: clientData, as: UTF8.self)
        == #"{"type":"webauthn.get","challenge":"\#(loginChallenge.base64URL)","origin":"https://mobile.x.com","crossOrigin":false}"#
    )
    #expect(try decodeBase64URL(reply["id"]) == authenticator.credential?.credentialID)
    #expect(try decodeBase64URL(reply["userHandle"]) == Data([1]))
    #expect(presence.confirmed.last == "sign in to x.com")
  }

  @Test func assertionAcceptsAnAllowListThatNamesTheCredential() async throws {
    let authenticator = authenticator()
    _ = try await authenticator.register(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, userHandle: Data([1]))
    let id = try #require(authenticator.credential?.credentialID)

    _ = try await authenticator.assertion(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, allowed: [Data([7]), id])
  }

  @Test func assertionRefusesWithoutACredential() async {
    await #expect(throws: Failure.self) {
      _ = try await authenticator().assertion(
        rpID: "x.com", origin: "https://x.com", challenge: challenge, allowed: [])
    }
    #expect(presence.confirmed.isEmpty)
  }

  @Test func assertionRefusesAnotherRPOrAnAllowListWithoutTheCredential() async throws {
    let authenticator = authenticator()
    _ = try await authenticator.register(
      rpID: "x.com", origin: "https://x.com", challenge: challenge, userHandle: Data([1]))

    await #expect(throws: Failure.self) {
      _ = try await authenticator.assertion(
        rpID: "example.com", origin: "https://example.com", challenge: challenge, allowed: [])
    }
    await #expect(throws: Failure.self) {
      _ = try await authenticator.assertion(
        rpID: "x.com", origin: "https://x.com", challenge: challenge, allowed: [Data([7])])
    }
    // Only the registration asked for the user.
    #expect(presence.confirmed.count == 1)
  }
}
