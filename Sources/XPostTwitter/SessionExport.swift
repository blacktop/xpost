import Darwin
import Foundation
import XPostCore

/// The cookie portion of Playwright's storage-state format. No other site's state is exported.
struct ExportedSession: Codable {
  struct Cookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Double
    let httpOnly: Bool
    let secure: Bool
    let sameSite: String

    init(_ cookie: HTTPCookie) {
      name = cookie.name
      value = cookie.value
      domain = cookie.domain
      path = cookie.path
      expires = cookie.expiresDate?.timeIntervalSince1970 ?? -1
      httpOnly = cookie.isHTTPOnly
      secure = cookie.isSecure
      switch cookie.sameSitePolicy?.rawValue.lowercased() {
      case "strict": sameSite = "Strict"
      case "none": sameSite = "None"
      default: sameSite = "Lax"
      }
    }
  }

  let cookies: [Cookie]
  let origins: [String]

  init(cookies: [HTTPCookie], accountID: String) throws {
    try validateExportAccountID(accountID)
    let applicable = composerCookies(in: cookies)
    guard applicable.contains(where: { $0.name == "auth_token" && !$0.value.isEmpty }),
      signedInUserID(in: applicable) == accountID
    else {
      throw Failure("session is not signed in as the expected X account; nothing was exported")
    }
    self.cookies = applicable.map(Cookie.init)
    origins = []
  }

  /// Publishes a fully written 0600 file without overwriting an existing file or symlink.
  func write(to destination: URL) throws {
    let directory = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var template = Array(directory.appending(path: ".xpost-session-XXXXXX").path.utf8CString)
    let descriptor = mkstemp(&template)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let temporary = URL(
      fileURLWithPath: String(
        decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
    defer { try? FileManager.default.removeItem(at: temporary) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    try file.write(contentsOf: JSONEncoder().encode(self))
    try file.synchronize()
    // A hard link publishes the private sibling atomically and fails if the output exists.
    guard link(temporary.path, destination.path) == 0 else {
      if errno == EEXIST { throw Failure("output already exists; choose a new session file") }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}

private func validateExportAccountID(_ accountID: String) throws {
  guard !accountID.isEmpty, accountID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
    throw Failure("set XPOST_TWITTER_ACCOUNT_ID to the expected account's numeric X id")
  }
}

extension TwitterCommands {
  /// Opens an isolated manual sign-in, verifies the composer and account, and exports cookies.
  /// The passkey store and saved Keychain session are never opened by this command.
  @MainActor
  public static func exportSession(accountID: String, to destination: URL, log: RunLog) async throws
  {
    try validateExportAccountID(accountID)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw Failure("output already exists; choose a new session file")
    }
    let browser = Browser(authenticator: nil, log: log)
    defer { browser.window.close() }
    browser.show()
    try browser.load(loginURL)
    log.report("Sign in to the account with X user id \(accountID) in this window.")
    log.report(
      "Use password sign-in or a passkey offered by WebKit. No passkey enrollment is required.")
    let deadline = ContinuousClock.now + .seconds(300)
    while browser.window.isVisible && ContinuousClock.now < deadline {
      try Task.checkCancellation()
      let cookies = await browser.sessionCookies()
      if cookies.contains(where: { $0.name == "auth_token" && !$0.value.isEmpty }),
        let signedIn = signedInUserID(in: cookies)
      {
        guard signedIn == accountID else {
          throw Failure(
            "signed in as X user id \(signedIn), expected \(accountID); nothing was exported")
        }
        guard try await openComposer(browser) else {
          throw Failure("X rejected the session when opening the composer; nothing was exported")
        }
        let visible = try await browser.js(
          """
          const el = document.querySelector(sel);
          if (!el) return false;
          const box = el.getBoundingClientRect();
          return box.width > 0 && box.height > 0 && getComputedStyle(el).visibility === "visible";
          """, arguments: ["sel": textareaSelector])
        guard browser.window.isVisible, browser.webView.url?.host == xHost,
          visible as? Bool == true
        else { throw Failure("X did not open a visible composer; nothing was exported") }
        let session = try ExportedSession(
          cookies: await browser.sessionCookies(), accountID: accountID)
        try Task.checkCancellation()
        try session.write(to: destination)
        log.report("Session exported to \(destination.path) for X user id \(accountID)")
        return
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    throw Failure(
      "sign-in was not completed before the window closed or five minutes elapsed; nothing was exported"
    )
  }
}
