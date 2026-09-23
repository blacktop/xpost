import Foundation

extension [String: String] {
  /// An environment setting with surrounding whitespace removed; empty when unset.
  public func setting(_ name: String) -> String {
    self[name, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Parses a server base URL from a setting, requiring http(s) and a host.
func serverURL(_ value: String, from name: String) throws -> URL {
  guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
    scheme == "https" || scheme == "http", url.host() != nil
  else {
    throw InvalidSetting(name: name, reason: "must be an http(s) URL, got \(quoted(value))")
  }
  return url
}
