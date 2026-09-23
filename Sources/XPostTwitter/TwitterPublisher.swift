import AppKit
import Darwin
import Foundation
import XPostCore

/// Where the enrolled passkey lives on disk.
public struct PasskeyStore: Sendable {
  let url: URL

  init(url: URL) {
    self.url = url
  }

  public static let `default` = PasskeyStore(
    url: FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/xpost/twitter-passkey.json"))

  /// The passkey enrolled before the current one, kept until X accepts the current one.
  var previousURL: URL {
    url.deletingPathExtension().appendingPathExtension("previous.json")
  }

  /// The enrolled passkey, or nil when none has been enrolled yet.
  func load() throws -> StoredCredential? {
    try read(url)
  }

  func loadPrevious() throws -> StoredCredential? {
    try read(previousURL)
  }

  /// Makes `stored` the current passkey. The one it replaces becomes the previous, unless
  /// a previous already exists: then the current one was never confirmed by X and the
  /// previous stays the last one that worked.
  func save(_ stored: StoredCredential) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = try stage(stored)
    defer { try? FileManager.default.removeItem(at: temporary) }
    if FileManager.default.fileExists(atPath: url.path),
      !FileManager.default.fileExists(atPath: previousURL.path)
    {
      try FileManager.default.moveItem(at: url, to: previousURL)
    }
    guard rename(temporary.path, url.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  /// Writes a private sibling file; the caller must publish it with rename or remove it.
  func stage(_ stored: StoredCredential) throws -> URL {
    let data = try JSONEncoder().encode(stored)
    var template = Array(
      url.deletingLastPathComponent().appending(path: ".twitter-passkey-XXXXXX").path.utf8CString)
    let descriptor = mkstemp(&template)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let temporary = URL(
      fileURLWithPath: String(
        decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try file.write(contentsOf: data)
      // On disk before the rename publishes it, so a crash cannot leave an empty passkey.
      try file.synchronize()
      try file.close()
      return temporary
    } catch {
      try? file.close()
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  func clearPrevious() throws {
    if FileManager.default.fileExists(atPath: previousURL.path) {
      try FileManager.default.removeItem(at: previousURL)
    }
  }

  private func read(_ file: URL) throws -> StoredCredential? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    do {
      return try JSONDecoder().decode(StoredCredential.self, from: Data(contentsOf: file))
    } catch {
      throw Failure("cannot read \(file.path): \(error); delete it and enroll again")
    }
  }
}

/// What a post to X needs: the account to sign in as and an enrolled passkey.
public struct TwitterConfig: Sendable {
  let user: String
  let credential: StoredCredential

  /// - Throws: `NotConfigured` when the user or the passkey is missing.
  public init(environment: [String: String], store: PasskeyStore) throws {
    let user = environment.setting("XPOST_TWITTER_USER")
    let credential = try store.load()
    guard !user.isEmpty, let credential else {
      throw NotConfigured(
        target: .twitter, missing: user.isEmpty ? ["XPOST_TWITTER_USER"] : [],
        hint: credential == nil ? "no passkey enrolled, run `xpost twitter enroll`" : nil)
    }
    self.user = user
    self.credential = credential
  }
}

/// Builds the X publisher. The browser is created when the post is made, on the main
/// actor, which must be running an AppKit run loop by then.
public func twitterPublisher(
  environment: [String: String], store: PasskeyStore, showsWindow: Bool, log: RunLog
) throws -> Publisher {
  let config = try TwitterConfig(environment: environment, store: store)
  return { request in
    try await publish(request, config: config, store: store, showsWindow: showsWindow, log: log)
  }
}

@MainActor
private func publish(
  _ request: Request, config: TwitterConfig, store: PasskeyStore, showsWindow: Bool,
  log: RunLog
) async throws {
  let authenticator = try makeAuthenticator(store: store, credential: config.credential, log: log)
  let browser = Browser(authenticator: authenticator, log: log)
  browser.present(visible: showsWindow)
  try await openComposerSignedIn(
    browser, user: config.user, credential: config.credential, showsWindow: showsWindow)
  do {
    try await compose(request, in: browser)
  } catch {
    await browser.snapshotFailure()
    throw error
  }
}

@MainActor
private func makeAuthenticator(
  store: PasskeyStore, credential: StoredCredential?, log: RunLog
) throws -> Authenticator {
  Authenticator(
    store: store, credential: credential, previous: try store.loadPrevious(),
    signer: SecureEnclaveSigner(), presence: TouchIDPresence(log: log), log: log)
}

/// The `xpost twitter` subcommands. Each needs an AppKit run loop except `logout`.
public enum TwitterCommands {
  @MainActor
  public static func enroll(store: PasskeyStore, log: RunLog) async throws {
    let authenticator = try makeAuthenticator(store: store, credential: try store.load(), log: log)
    try await XPostTwitter.enroll(Browser(authenticator: authenticator, log: log), authenticator)
  }

  /// Returns what X's login page experiences in this browser, without signing in.
  @MainActor
  public static func probe(store: PasskeyStore, showsWindow: Bool, log: RunLog) async throws
    -> String
  {
    let authenticator = try makeAuthenticator(store: store, credential: try store.load(), log: log)
    let browser = Browser(authenticator: authenticator, log: log)
    browser.present(visible: showsWindow)
    return try await XPostTwitter.probe(browser)
  }

  /// Forgets the saved session, so the next post signs in with the passkey again.
  public static func logout() throws {
    try SessionStore.clear()
  }
}
