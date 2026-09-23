// Replaces navigator.credentials in the page so WebAuthn ceremonies reach Authenticator.

import AppKit
import WebKit
import XPostCore

@MainActor
final class WebAuthnBridge: NSObject, WKScriptMessageHandlerWithReply {
  private static let handlerName = "xpost"
  /// How long X gets to act on a ceremony's reply before sign-in presses anything again.
  private static let settleSeconds: TimeInterval = 3

  private let authenticator: Authenticator
  private let log: RunLog
  private(set) var activeRequestCount = 0
  private var lastFinished: Date?
  private var explainedMissingPasskey = false

  /// Pauses automated sign-in while a WebAuthn ceremony is being handled and briefly after
  /// it ends, so a button still on screen is not pressed while X signs in with the reply.
  var isBusy: Bool {
    if activeRequestCount > 0 { return true }
    guard let lastFinished else { return false }
    return Date().timeIntervalSince(lastFinished) < Self.settleSeconds
  }

  init(authenticator: Authenticator, log: RunLog) {
    self.authenticator = authenticator
    self.log = log
  }

  func install(on controller: WKUserContentController) {
    let enrolled = authenticator.credential != nil
    let source = shimJS.replacingOccurrences(of: "__ENROLLED__", with: String(enrolled))
    controller.addUserScript(
      WKUserScript(
        source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false,
        in: .page))
    controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) async -> (Any?, String?) {
    if let body = message.body as? [String: Any], body["op"] as? String == "log" {
      log.note("page: \(body["message"] as? String ?? "")")
      return (nil, nil)
    }
    do {
      // The origin comes from WebKit, not from the page, so a page cannot lie about it.
      let security = message.frameInfo.securityOrigin
      return (
        try await handle(
          message.body, isMainFrame: message.frameInfo.isMainFrame,
          scheme: security.protocol, host: security.host), nil
      )
    } catch {
      log.note("webauthn request failed: \(error)")
      return (nil, "\(error)")
    }
  }

  /// Passkeys in iCloud Keychain or a password manager are out of reach for a WKWebView,
  /// so pressing X's passkey button before enrolling can only fail. Say why in the window.
  private func explainMissingPasskey() {
    guard !explainedMissingPasskey else { return }
    explainedMissingPasskey = true
    let alert = NSAlert()
    alert.messageText = "Your existing passkeys are not available here"
    alert.informativeText =
      "xpost cannot reach passkeys stored in iCloud Keychain or a password manager. "
      + "Dismiss this, pick X's password option, then create a new passkey under "
      + "Settings > Security and account access > Security > Passkeys."
    alert.runModal()
  }

  func handle(_ message: Any, isMainFrame: Bool, scheme: String, host: String) async throws
    -> [String: Any]
  {
    guard isMainFrame else {
      throw Failure("webauthn request from a subframe")
    }
    activeRequestCount += 1
    defer {
      activeRequestCount -= 1
      lastFinished = Date()
    }
    guard let body = message as? [String: Any],
      let operation = body["op"] as? String,
      let rpID = body["rpId"] as? String,
      let challenge = (body["challenge"] as? String).flatMap(Data.init(base64URL:))
    else { throw Failure("malformed webauthn request") }

    let origin = try WebAuthn.origin(protocol: scheme, host: host, rpID: rpID)
    guard rpID == xHost else {
      throw Failure("webauthn request for \(rpID); xpost's passkey is only for \(xHost)")
    }
    log.note("webauthn \(operation) for \(rpID) from \(origin)")

    switch operation {
    case "create":
      guard let userHandle = (body["userId"] as? String).flatMap(Data.init(base64URL:))
      else { throw Failure("create request has no user id") }
      return try await authenticator.register(
        rpID: rpID, origin: origin, challenge: challenge, userHandle: userHandle)
    case "get":
      guard authenticator.credential != nil else {
        explainMissingPasskey()
        throw Failure("passkey sign-in requested before enrollment")
      }
      let allowed = (body["allowCredentials"] as? [String] ?? [])
        .compactMap(Data.init(base64URL:))
      return try await authenticator.assertion(
        rpID: rpID, origin: origin, challenge: challenge, allowed: allowed)
    default:
      throw Failure("unknown webauthn operation \(operation)")
    }
  }
}

private let shimJS = #"""
  (() => {
      const enrolled = __ENROLLED__;
      const bytes = v => v instanceof ArrayBuffer
          ? new Uint8Array(v) : new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
      const enc = v => btoa(String.fromCharCode(...bytes(v)))
          .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
      const dec = s => Uint8Array.from(
          atob(s.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0)).buffer;

      const note = message =>
          window.webkit.messageHandlers.xpost.postMessage({op: "log", message});
      if (window === top) note(`loaded ${location.origin}${location.pathname}`);

      const native = async body => {
          try {
              return await window.webkit.messageHandlers.xpost.postMessage(body);
          } catch (e) {
              throw new DOMException(String((e && e.message) || e), "NotAllowedError");
          }
      };

      // Own properties shadow the prototype's getters, so instanceof checks still pass.
      const build = (ctor, fields) => {
          const object = Object.create(ctor ? ctor.prototype : Object.prototype);
          for (const [key, value] of Object.entries(fields)) {
              Object.defineProperty(object, key, {value, enumerable: true});
          }
          return object;
      };

      if (!window.PublicKeyCredential) {
          window.PublicKeyCredential = function PublicKeyCredential() {};
      }
      PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = async () => true;
      PublicKeyCredential.isConditionalMediationAvailable = async () => true;

      const credential = (id, response, responseJSON) => build(PublicKeyCredential, {
          id,
          rawId: dec(id),
          type: "public-key",
          authenticatorAttachment: "platform",
          response,
          getClientExtensionResults: () => ({}),
          toJSON: () => ({
              id, rawId: id, type: "public-key", authenticatorAttachment: "platform",
              clientExtensionResults: {}, response: responseJSON,
          }),
      });

      const create = async options => {
          note(`credentials.create called; algs: ${options.pubKeyCredParams.map(p => p.alg)}`);
          if (!options.pubKeyCredParams.some(p => p.alg === -7)) {
              throw new DOMException("ES256 not accepted", "NotSupportedError");
          }
          const r = await native({
              op: "create",
              rpId: options.rp.id || location.hostname,
              challenge: enc(options.challenge),
              userId: enc(options.user.id),
          });
          const response = build(window.AuthenticatorAttestationResponse, {
              clientDataJSON: dec(r.clientDataJSON),
              attestationObject: dec(r.attestationObject),
              getAuthenticatorData: () => dec(r.authenticatorData),
              getPublicKey: () => dec(r.publicKey),
              getPublicKeyAlgorithm: () => -7,
              getTransports: () => ["internal"],
          });
          return credential(r.id, response, {
              clientDataJSON: r.clientDataJSON,
              attestationObject: r.attestationObject,
              authenticatorData: r.authenticatorData,
              publicKey: r.publicKey,
              publicKeyAlgorithm: -7,
              transports: ["internal"],
          });
      };

      const get = async (options, mediation) => {
          note(`credentials.get called; mediation: ${mediation || "modal"}`);
          // Autofill-style requests must stay pending when there is nothing to offer.
          if (mediation === "conditional" && !enrolled) return new Promise(() => {});
          const r = await native({
              op: "get",
              rpId: options.rpId || location.hostname,
              challenge: enc(options.challenge),
              allowCredentials: (options.allowCredentials || []).map(c => enc(c.id)),
          });
          const response = build(window.AuthenticatorAssertionResponse, {
              clientDataJSON: dec(r.clientDataJSON),
              authenticatorData: dec(r.authenticatorData),
              signature: dec(r.signature),
              userHandle: dec(r.userHandle),
          });
          return credential(r.id, response, {
              clientDataJSON: r.clientDataJSON,
              authenticatorData: r.authenticatorData,
              signature: r.signature,
              userHandle: r.userHandle,
          });
      };

      if (!navigator.credentials) {
          Object.defineProperty(navigator, "credentials", {value: {}});
      }
      const container = navigator.credentials;
      const unsupported = () =>
          Promise.reject(new DOMException("only public-key credentials", "NotSupportedError"));
      const originalCreate = container.create ? container.create.bind(container) : unsupported;
      const originalGet = container.get ? container.get.bind(container) : unsupported;
      container.create = o => (o && o.publicKey ? create(o.publicKey) : originalCreate(o));
      container.get = o => (o && o.publicKey ? get(o.publicKey, o.mediation) : originalGet(o));
  })();
  """#
