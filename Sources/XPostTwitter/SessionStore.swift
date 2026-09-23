// Keeps X's session cookies in the login keychain so most runs skip the sign-in.
//
// The file-based login keychain needs no entitlements, unlike the data-protection keychain.
// Access is tied to the binary's signature: an ad-hoc build changes it on every rebuild, so
// macOS asks for the keychain password again until the tool is signed with a stable identity.

import Foundation
import Security
import XPostCore

/// The cookies of one signed-in X account, keyed by X's numeric user id: the value the
/// passkey's user handle holds and the `twid` cookie repeats.
struct SavedSession {
  let userID: String
  let cookies: [HTTPCookie]
}

/// Only cookies WebKit can send to the composer may establish its identity.
func composerCookies(in cookies: [HTTPCookie]) -> [HTTPCookie] {
  guard let url = URL(string: composeURL), let host = url.host else { return [] }
  return cookies.filter { cookie in
    let domain = cookie.domain.lowercased()
    let domainMatches =
      domain.hasPrefix(".")
      ? host == String(domain.dropFirst()) || host.hasSuffix(domain)
      : host == domain
    let pathMatches =
      url.path == cookie.path
      || (url.path.hasPrefix(cookie.path)
        && (cookie.path.hasSuffix("/") || url.path.dropFirst(cookie.path.count).hasPrefix("/")))
    return domainMatches && pathMatches
      && (!cookie.isSecure || url.scheme == "https")
      && (cookie.expiresDate.map { $0 > Date() } ?? true)
  }
}

/// Conflicting or malformed applicable identities cannot vouch for an account.
func signedInUserID(in cookies: [HTTPCookie]) -> String? {
  var ids = Set<String>()
  for twid in composerCookies(in: cookies) where twid.name == "twid" {
    guard let value = twid.value.removingPercentEncoding, value.hasPrefix("u=") else {
      return nil
    }
    let id = value.dropFirst(2)
    guard !id.isEmpty, id.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
    ids.insert(String(id))
  }
  return ids.count == 1 ? ids.first : nil
}

enum SessionStore {
  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "io.blacktop.xpost",
      kSecAttrAccount as String: "x-session",
    ]
  }

  /// The saved session, or nil when there is none. It may belong to another account.
  static func load() throws -> SavedSession? {
    var lookup = query
    lookup[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw Failure("cannot read the saved session: \(message(status))")
    }
    return try decode(data)
  }

  static func save(_ session: SavedSession) throws {
    let data = try encode(session)

    let update = [kSecValueData as String: data]
    var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrLabel as String] = "xpost X session"
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw Failure("cannot save the session: \(message(status))")
    }
  }

  static func clear() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure("cannot delete the saved session: \(message(status))")
    }
  }

  /// A binary property list: the account and each cookie's properties.
  static func encode(_ session: SavedSession) throws -> Data {
    let entries: [[String: Any]] = session.cookies.compactMap { cookie in
      guard let properties = cookie.properties else { return nil }
      let pairs = properties.map { ($0.key.rawValue, $0.value) }
      return Dictionary(uniqueKeysWithValues: pairs)
    }
    return try PropertyListSerialization.data(
      fromPropertyList: ["userID": session.userID, "cookies": entries], format: .binary,
      options: 0)
  }

  static func decode(_ data: Data) throws -> SavedSession {
    let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil)
    guard let saved = decoded as? [String: Any], let userID = saved["userID"] as? String,
      let entries = saved["cookies"] as? [[String: Any]]
    else {
      throw Failure("saved session is malformed; run `xpost twitter logout`")
    }
    let cookies = entries.compactMap { entry in
      let properties = entry.map { (HTTPCookiePropertyKey($0.key), $0.value) }
      return HTTPCookie(properties: Dictionary(uniqueKeysWithValues: properties))
    }
    return SavedSession(userID: userID, cookies: cookies)
  }

  private static func message(_ status: OSStatus) -> String {
    let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
    return "\(text) (\(status))"
  }
}
