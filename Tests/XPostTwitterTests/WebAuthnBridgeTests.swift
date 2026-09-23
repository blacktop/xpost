import Foundation
import LocalAuthentication
import Testing
import XPostCore

@testable import XPostTwitter

private enum CeremonyOutcome: CaseIterable, Sendable {
  case success, rejected, cancelled, malformed
}

@MainActor
private final class InspectingPresence: PresenceCheck {
  var outcome = CeremonyOutcome.success
  var inspect: () -> Void = {}

  func confirm(reason: String) async throws -> LAContext? {
    inspect()
    await Task.yield()
    switch outcome {
    case .rejected: throw Failure("presence rejected")
    case .cancelled: throw CancellationError()
    default: return nil
    }
  }
}

@Suite @MainActor struct WebAuthnBridgeTests {
  private let store = temporaryStore()
  private let presence = InspectingPresence()

  private var create: [String: Any] {
    [
      "op": "create", "rpId": "x.com", "challenge": Data([1]).base64URL,
      "userId": Data([2]).base64URL,
    ]
  }

  private func makeBridge() -> WebAuthnBridge {
    let authenticator = Authenticator(
      store: store, credential: nil, previous: nil, signer: InMemorySigner(), presence: presence,
      log: testLog)
    return WebAuthnBridge(authenticator: authenticator, log: testLog)
  }

  @Test(arguments: CeremonyOutcome.allCases)
  fileprivate func completedCeremoniesDoNotBlockSignIn(outcome: CeremonyOutcome) async throws {
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    presence.outcome = outcome
    let bridge = makeBridge()
    presence.inspect = { [weak bridge] in #expect(bridge?.activeRequestCount == 1) }

    if outcome == .success {
      _ = try await bridge.handle(create, isMainFrame: true, scheme: "https", host: "x.com")
    } else {
      await #expect(throws: (any Error).self) {
        _ = try await bridge.handle(
          outcome == .malformed ? [:] : create,
          isMainFrame: true, scheme: "https", host: "x.com")
      }
    }
    #expect(bridge.activeRequestCount == 0)

    presence.outcome = .success
    _ = try await bridge.handle(create, isMainFrame: true, scheme: "https", host: "x.com")
    #expect(bridge.activeRequestCount == 0)
    #expect(try store.load()?.rpID == "x.com")
  }

  @Test func onlyAMainFrameCeremonyHoldsSignInAfterItEnds() async throws {
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    let bridge = makeBridge()
    #expect(!bridge.isBusy)

    await #expect(throws: Failure.self) {
      _ = try await bridge.handle(create, isMainFrame: false, scheme: "https", host: "x.com")
    }
    #expect(!bridge.isBusy)

    _ = try await bridge.handle(create, isMainFrame: true, scheme: "https", host: "x.com")
    #expect(bridge.activeRequestCount == 0)
    #expect(bridge.isBusy)
  }

  @Test(arguments: ["example.com", "mobile.x.com", "x.com.evil"])
  func refusesEveryOtherSite(rpID: String) async throws {
    defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
    let bridge = makeBridge()
    presence.inspect = { Issue.record("Touch ID was asked for \(rpID)") }
    var request = create
    request["rpId"] = rpID

    await #expect(throws: Failure.self) {
      _ = try await bridge.handle(request, isMainFrame: true, scheme: "https", host: rpID)
    }

    #expect(try store.load() == nil)
  }
}
