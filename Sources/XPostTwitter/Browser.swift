// Posting to X through a WKWebView instead of the paid API.
//
// Sign-in uses xpost's own passkey: a Secure Enclave key that signs only after Touch ID.
// The session cookies are kept in the login keychain, so Touch ID is only needed when X
// ends the session.

import AppKit
import Darwin
import WebKit
import XPostCore

/// The only site xpost signs in to, and the relying party of its passkey.
let xHost = "x.com"
let loginURL = "https://\(xHost)/i/flow/login?lang=en"
let composeURL = "https://\(xHost)/compose/post?lang=en"
let textareaSelector = "[data-testid=\"tweetTextarea_0\"]"
let postButtonSelector = "[data-testid=\"tweetButton\"]"
let toastSelector = "[data-testid=\"toast\"]"
let fileInputSelector = "input[data-testid=\"fileInput\"]"
let attachmentsSelector = "[data-testid=\"attachments\"]"

func safariVersion() -> String {
  let info = Bundle(path: "/Applications/Safari.app")?.infoDictionary
  return info?["CFBundleShortVersionString"] as? String ?? "26.0"
}

@MainActor
final class Browser: NSObject, WKUIDelegate {
  let webView: WKWebView
  let window: NSWindow
  let bridge: WebAuthnBridge?
  let log: RunLog
  /// Files to hand to the page the next time it opens a file chooser.
  var pendingUploads: [URL] = []

  init(authenticator: Authenticator?, log: RunLog) {
    self.log = log
    bridge = authenticator.map { WebAuthnBridge(authenticator: $0, log: log) }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    // WKWebView omits the Version/Safari tokens that real Safari sends.
    config.applicationNameForUserAgent = "Version/\(safariVersion()) Safari/605.1.15"
    bridge?.install(on: config.userContentController)

    let frame = NSRect(x: 0, y: 0, width: 1100, height: 850)
    webView = WKWebView(frame: frame, configuration: config)
    // The view lives in a window even when hidden so WebKit lays the page out normally.
    window = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "xpost"
    window.isReleasedWhenClosed = false
    window.contentView = webView
    super.init()
    webView.uiDelegate = self
    webView.isInspectable = true
  }

  /// Without this, window.open and target=_blank links do nothing. Load them in place.
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    let url = navigationAction.request.url?.absoluteString ?? "none"
    log.note("page opened a new window for \(url); loading it in place")
    webView.load(navigationAction.request)
    return nil
  }

  /// Answers the page's file chooser with the queued files instead of showing a panel.
  func webView(
    _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void
  ) {
    log.note("page opened a file chooser; supplying \(pendingUploads.count) file(s)")
    completionHandler(pendingUploads.isEmpty ? nil : pendingUploads)
    pendingUploads = []
  }

  func show() {
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// WebKit stops timers and rendering for a page whose window is not on screen, and X's
  /// pages never finish loading in that state. Keep the window on screen but invisible.
  func runHidden() {
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.transient, .ignoresCycle]
    window.orderFrontRegardless()
  }

  /// Shows or hides the window as the user asked.
  func present(visible: Bool) {
    if visible { show() } else { runHidden() }
  }

  /// Clicks with real AppKit mouse events. X ignores script-made clicks on some buttons,
  /// and these arrive in the page as trusted input. `x`/`y` are CSS viewport coordinates.
  func click(x: Double, y: Double) throws {
    // WKWebView is a flipped view: y already counts from the top, like the page does.
    let inView = NSPoint(x: x, y: webView.isFlipped ? y : Double(webView.bounds.height) - y)
    let inWindow = webView.convert(inView, to: nil)
    for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
      guard
        let event = NSEvent.mouseEvent(
          with: type, location: inWindow, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
          clickCount: type == .mouseMoved ? 0 : 1,
          pressure: type == .leftMouseDown ? 1 : 0)
      else { throw Failure("could not build a mouse event") }
      switch type {
      case .mouseMoved: webView.mouseMoved(with: event)
      case .leftMouseDown: webView.mouseDown(with: event)
      default: webView.mouseUp(with: event)
      }
    }
  }

  /// Clicks the centre of the match for `selector` that a click would actually reach; X
  /// keeps covered copies of some controls in the DOM.
  func click(selector: String) async throws {
    let found = try await js(
      """
      const report = [];
      for (const el of document.querySelectorAll(sel)) {
          const box = el.getBoundingClientRect();
          const x = box.x + box.width / 2, y = box.y + box.height / 2;
          const hit = document.elementFromPoint(x, y);
          if (hit && (el === hit || el.contains(hit))) return {x, y};
          const testid = hit ? hit.getAttribute("data-testid") || "" : "";
          const name = hit ? `${hit.tagName}.${testid}` : "nothing";
          report.push(`${Math.round(x)},${Math.round(y)} covered by ${name}`);
      }
      return {report};
      """, arguments: ["sel": selector])
    guard let found = found as? [String: Any], let x = found["x"] as? Double,
      let y = found["y"] as? Double
    else {
      let coverage = (found as? [String: Any])?["report"] ?? "no match"
      throw Failure("nothing clickable matches \(selector): \(coverage)")
    }
    log.note("clicking \(selector) at \(Int(x)),\(Int(y))")
    try click(x: x, y: y)
  }

  func load(_ url: String) throws {
    guard let parsed = URL(string: url) else { throw Failure("bad URL \(url)") }
    var request = URLRequest(url: parsed)
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    webView.load(request)
  }

  /// `body` must return a value: WebKit's async bridge traps on an undefined result.
  func js(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
    try await webView.callAsyncJavaScript(
      body, arguments: arguments, in: nil, contentWorld: .page)
  }

  private var cookieStore: WKHTTPCookieStore {
    webView.configuration.websiteDataStore.httpCookieStore
  }

  func sessionCookies() async -> [HTTPCookie] {
    composerCookies(in: await cookieStore.allCookies())
  }

  func hasAuthCookie() async -> Bool {
    await sessionCookies().contains { $0.name == "auth_token" }
  }

  func restore(_ cookies: [HTTPCookie]) async {
    for cookie in cookies { await cookieStore.setCookie(cookie) }
  }

  func forgetSession() async {
    for cookie in await cookieStore.allCookies() { await cookieStore.deleteCookie(cookie) }
  }

  /// Polls until `selector` matches. Evaluation errors during navigation are expected.
  func waitFor(_ selector: String, timeout: Double) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let found = try? await js(
        "return !!document.querySelector(sel)", arguments: ["sel": selector])
      if found as? Bool == true { return }
      try await Task.sleep(for: .seconds(0.5))
    }
    let url = webView.url?.absoluteString ?? "none"
    throw Failure("timed out waiting for \(selector) (url: \(url))")
  }

  func snapshot(to path: String) async throws {
    let image = try await webView.takeSnapshot(configuration: nil)
    guard let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { throw Failure("could not encode screenshot") }
    try png.write(to: URL(fileURLWithPath: path))
    log.report("screenshot written to \(path)")
  }

  /// The page state is the only evidence of why X did not do what was asked.
  func snapshotFailure() async {
    guard let path = try? failureScreenshotPath() else { return }
    try? await snapshot(to: path)
  }
}
