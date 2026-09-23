import Foundation
import XPostCore

/// What posting to X through the Chromium helper needs, from the environment.
///
/// - `XPOST_TWITTER_HELPER`: the helper directory (contains `dist/helper.js` and `node_modules`).
/// - `XPOST_TWITTER_USER`: the username typed into the login form.
/// - `XPOST_TWITTER_ACCOUNT_ID`: X's numeric user id the signed-in account must have.
/// - `XPOST_TWITTER_PASSWORD` and/or `XPOST_TWITTER_STATE_FILE`: how to sign in. The state
///   file is a Playwright storage state; it is a credential, read when present and written
///   after a verified password login.
/// - `XPOST_TWITTER_BASE_URL`: where X is; only fixture servers change it.
struct ChromiumConfig: Sendable {
  let helperScript: String
  let user: String
  let accountID: String
  let password: String?
  let stateFile: String?
  let baseURL: String

  init(environment: [String: String]) throws {
    // Byte for byte: a password may begin or end with whitespace.
    let password = environment["XPOST_TWITTER_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 }
    let stateFile = environment.setting("XPOST_TWITTER_STATE_FILE")
    let missing = ["XPOST_TWITTER_HELPER", "XPOST_TWITTER_USER", "XPOST_TWITTER_ACCOUNT_ID"]
      .filter { environment.setting($0).isEmpty }
    let hint =
      password == nil && stateFile.isEmpty
      ? "set XPOST_TWITTER_PASSWORD or XPOST_TWITTER_STATE_FILE to sign in" : nil
    guard missing.isEmpty, hint == nil else {
      throw NotConfigured(target: .twitter, missing: missing, hint: hint)
    }

    // ASCII digits only, the same rule the helper applies.
    let accountID = environment.setting("XPOST_TWITTER_ACCOUNT_ID")
    guard accountID.allSatisfy({ $0.isASCII && $0.isNumber }) else {
      throw InvalidSetting(
        name: "XPOST_TWITTER_ACCOUNT_ID", reason: "must be X's numeric user id, got \(accountID)")
    }
    let script = URL(fileURLWithPath: environment.setting("XPOST_TWITTER_HELPER"))
      .appending(path: "dist/helper.js").path
    guard FileManager.default.isReadableFile(atPath: script) else {
      throw InvalidSetting(
        name: "XPOST_TWITTER_HELPER",
        reason: "has no dist/helper.js; run `pnpm install && pnpm build` in helper/")
    }

    let baseURL = environment.setting("XPOST_TWITTER_BASE_URL")
    self.helperScript = script
    self.user = environment.setting("XPOST_TWITTER_USER")
    self.accountID = accountID
    self.password = password
    self.stateFile = stateFile.isEmpty ? nil : stateFile
    self.baseURL = baseURL.isEmpty ? "https://x.com" : baseURL
  }
}
