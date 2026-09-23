import Foundation
import XPostCore

/// How often sign-in presses one button before it stops offering it.
let maxPresses = 3

// One step through X's login screens, using the field and button names X served in
// September 2026. It only locates the button to press; Swift does the clicking.
// `done` lists buttons that have used up their presses.
let signInStepJS = """
  const label = el => el.innerText.trim();
  // X keeps covered copies of some buttons in the DOM; only the copy that a click at its
  // centre would actually reach is the live one.
  const onTop = el => {
      const box = el.getBoundingClientRect();
      const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
      return !!hit && (el === hit || el.contains(hit));
  };
  const buttons = [...document.querySelectorAll("button, [role=button]")]
      .filter(el => label(el) && onTop(el));
  const find = pattern => {
      const button = buttons.find(el => pattern.test(label(el)) && !done.includes(label(el)));
      if (!button) return null;
      const box = button.getBoundingClientRect();
      return {label: label(button), x: box.x + box.width / 2, y: box.y + box.height / 2};
  };

  // Screen 1 asks for the username; screen 2 wants an emailed code, and
  // "Use password" is what makes X start the passkey ceremony instead.
  const inputs = [...document.querySelectorAll("input")].filter(el =>
      el.type === "text" && el.offsetParent !== null);
  const challenge = inputs.find(el =>
      el.name === "challenge_response" || el.autocomplete === "one-time-code");
  // X renders the username field twice and may wipe it while the page is still loading,
  // so fill every copy that does not hold the username yet, on every step.
  const usernames = inputs.filter(el => el.name === "username_or_email");
  const unfilled = usernames.filter(el => el.value !== user);
  let target = null;
  let enteredUser = false;
  if (challenge) {
      target = find(/^use password$/i);
  } else if (unfilled.length > 0) {
      // React ignores direct writes to .value; go through the native setter and notify it.
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
      for (const el of unfilled) {
          setter.call(el, user);
          el.dispatchEvent(new Event("input", {bubbles: true}));
      }
      enteredUser = true;
  } else if (usernames.length > 0) {
      target = find(/^continue$/i);
  }
  return {
      target, enteredUser,
      visibility: document.visibilityState,
      labels: buttons.map(label).slice(0, 12),
      inputs: inputs.map(el => `${el.type}/${el.name}/${el.autocomplete}/${el.placeholder}`),
  };
  """

/// Signs in with the passkey by stepping through X's login screens until X starts the
/// WebAuthn ceremony, which the bridge answers after Touch ID.
@MainActor
func signIn(_ browser: Browser, user: String, timeout: Double) async throws {
  let log = browser.log
  try browser.load(loginURL)
  let started = Date()
  var lastLabels: [String] = []
  var presses: [String: Int] = [:]
  var nextHeartbeat = 10.0
  while Date().timeIntervalSince(started) < timeout {
    if await browser.hasAuthCookie() {
      log.note("signed in")
      return
    }
    try await Task.sleep(for: .seconds(1))
    let elapsed = Date().timeIntervalSince(started)
    if elapsed >= nextHeartbeat {
      nextHeartbeat += 10
      let url = browser.webView.url?.absoluteString ?? "none"
      log.note(
        "still signing in after \(Int(elapsed))s: url=\(url) "
          + "loading=\(browser.webView.isLoading) "
          + "active webauthn requests=\(browser.bridge.activeRequestCount)")
    }
    guard !browser.bridge.isBusy else { continue }

    let done = presses.filter { $0.value >= maxPresses }.map(\.key)
    let arguments: [String: Any] = ["user": user, "done": done]
    guard let step = try? await browser.js(signInStepJS, arguments: arguments) as? [String: Any]
    else { continue }
    let labels = step["labels"] as? [String] ?? []
    if labels != lastLabels {
      lastLabels = labels
      log.note("login screen (\(step["visibility"] ?? "?")) buttons: \(labels)")
      log.note("login screen inputs (type/name/autocomplete/placeholder): \(step["inputs"] ?? [])")
    }
    if step["enteredUser"] as? Bool == true { log.note("entered username") }
    // X may have started a ceremony while the step script ran.
    guard !browser.bridge.isBusy else { continue }
    if let target = step["target"] as? [String: Any], let pressed = target["label"] as? String,
      let x = target["x"] as? Double, let y = target["y"] as? Double
    {
      try browser.click(x: x, y: y)
      presses[pressed, default: 0] += 1
      log.note("pressed \(pressed.debugDescription)")
      // Give the screen time to change before deciding the press did nothing.
      try await Task.sleep(for: .seconds(3))
    }
  }
  let url = browser.webView.url?.absoluteString ?? "none"
  await browser.snapshotFailure()
  throw Failure(
    "sign-in did not finish in \(Int(timeout))s (url: \(url)); retry with --show-browser")
}

/// Opens the composer. True if X showed it, false if X sent us to its login flow instead.
@MainActor
func openComposer(_ browser: Browser) async throws -> Bool {
  try browser.load(composeURL)
  let deadline = Date().addingTimeInterval(30)
  while Date() < deadline {
    try await Task.sleep(for: .seconds(0.5))
    let found = try? await browser.js(
      "return !!document.querySelector(sel)", arguments: ["sel": textareaSelector])
    if found as? Bool == true { return true }
    if let path = browser.webView.url?.path, authFlowPaths.contains(where: path.hasPrefix) {
      return false
    }
  }
  let url = browser.webView.url?.absoluteString ?? "none"
  throw Failure("composer did not open in 30s (url: \(url))")
}

/// Reuses the session saved in the keychain, and signs in with the passkey only when X no
/// longer accepts it. Either way the session must belong to the passkey's account.
@MainActor
func openComposerSignedIn(
  _ browser: Browser, user: String, credential: StoredCredential, showsWindow: Bool
) async throws {
  let log = browser.log
  let account = String(decoding: credential.userHandle, as: UTF8.self)
  if let saved = try SessionStore.load() {
    if saved.userID == account {
      await browser.restore(saved.cookies)
      if try await openComposer(browser) {
        if signedInUserID(in: await browser.sessionCookies()) == account {
          log.note("saved session accepted")
          return
        }
        // Labelled for this account but not signed in as it: as good as rejected.
        log.note("saved session is not signed in as user id \(account); signing in again")
      } else {
        log.note("saved session rejected; signing in again")
      }
      await browser.forgetSession()
    } else {
      log.note("saved session belongs to user id \(saved.userID), not \(account); signing in again")
    }
    try SessionStore.clear()
  }

  // A visible window leaves time to finish the sign-in by hand if X asks for more.
  try await signIn(browser, user: user, timeout: showsWindow ? 300 : 90)
  try await verifyAccount(browser, is: account)
  try SessionStore.save(SavedSession(userID: account, cookies: await browser.sessionCookies()))
  log.note("session for user id \(account) saved to the keychain")
  guard try await openComposer(browser) else {
    throw Failure("X asked to sign in again right after signing in")
  }
}

/// A sign-in finished by hand in a visible window can be for any account; only the one the
/// passkey belongs to may post.
@MainActor
private func verifyAccount(_ browser: Browser, is account: String) async throws {
  let signedIn = signedInUserID(in: await browser.sessionCookies())
  guard signedIn == account else {
    await browser.forgetSession()
    throw Failure(
      "signed in as X user id \(signedIn ?? "unknown"), but the passkey belongs to \(account)")
  }
}

/// One-time setup: the user signs in by hand and adds a passkey in X's settings; the
/// WebAuthn bridge answers the creation ceremony with a new Secure Enclave key.
@MainActor
func enroll(_ browser: Browser, _ authenticator: Authenticator) async throws {
  let log = browser.log
  let previous = authenticator.credential?.credentialID
  try browser.load(loginURL)
  browser.show()
  log.report("1. sign in to X with your password")
  log.report("2. open Settings > Security and account access > Security > Passkeys")
  log.report("3. create a passkey and approve the Touch ID prompt")
  log.report("4. finish X's dialog, then close this window")
  while browser.window.isVisible {
    try await Task.sleep(for: .seconds(0.5))
  }
  guard let current = authenticator.credential?.credentialID, current != previous else {
    throw Failure("window closed before X requested a new passkey")
  }
  log.report(
    "passkey created: \(current.base64URL); the previous one is kept until X accepts it")
}

/// Loads X's login page the way a post would and returns, as JSON, what the page
/// experiences without signing in. Shows whether the hidden window keeps the page alive.
@MainActor
func probe(_ browser: Browser) async throws -> String {
  try browser.load(loginURL)
  try await browser.waitFor("input[name=username_or_email]", timeout: 30)
  let health = try await browser.js(
    """
    let frames = 0;
    const tick = () => { frames++; requestAnimationFrame(tick); };
    requestAnimationFrame(tick);
    await new Promise(resolve => setTimeout(resolve, 2000));
    const buttons = [...document.querySelectorAll("button, [role=button]")];
    return {
        visibility: document.visibilityState,
        focused: document.hasFocus(),
        framesIn2s: frames,
        buttons: buttons.map(el => el.innerText.trim()).filter(Boolean).slice(0, 8),
    };
    """)
  guard let health, JSONSerialization.isValidJSONObject(health) else {
    throw Failure("probe script returned no report")
  }
  let json = try JSONSerialization.data(
    withJSONObject: health, options: [.prettyPrinted, .sortedKeys])
  return String(decoding: json, as: UTF8.self)
}
