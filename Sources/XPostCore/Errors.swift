/// A target that cannot be used because its configuration is incomplete.
public struct NotConfigured: Error, Equatable, CustomStringConvertible {
  public let target: Target
  public let missing: [String]
  /// What to do about a prerequisite that is not an environment variable.
  public let hint: String?

  public init(target: Target, missing: [String], hint: String? = nil) {
    self.target = target
    self.missing = missing
    self.hint = hint
  }

  /// The reason without the target name, for lines that already name the target.
  var reason: String {
    var details: [String] = []
    if !missing.isEmpty {
      details.append("missing \(missing.joined(separator: ", "))")
    }
    if let hint {
      details.append(hint)
    }
    if details.isEmpty {
      return "credentials not configured"
    }
    return "credentials not configured (\(details.joined(separator: "; ")))"
  }

  public var description: String { "\(target.rawValue) \(reason)" }
}

/// A setting that is present but unusable.
public struct InvalidSetting: Error, Equatable, CustomStringConvertible {
  public let name: String
  public let reason: String

  public init(name: String, reason: String) {
    self.name = name
    self.reason = reason
  }

  public var description: String { "\(name) \(reason)" }
}

/// A request that a target's constraints reject.
public struct ValidationError: Error, Equatable, CustomStringConvertible {
  public let target: Target
  public let reason: String

  public init(target: Target, reason: String) {
    self.target = target
    self.reason = reason
  }

  public var description: String { "\(target.rawValue) validation failed: \(reason)" }
}

/// Invalid command input that stops the run before any target is tried.
public struct UsageError: Error, Equatable, CustomStringConvertible {
  public let description: String

  init(_ description: String) {
    self.description = description
  }
}

/// One or more targets were skipped or failed; carries every failure, one per line.
public struct PostFailure: Error, CustomStringConvertible {
  public let failures: [TargetFailure]

  public var description: String {
    failures.map(\.description).joined(separator: "\n")
  }
}

public struct TargetFailure: Error, CustomStringConvertible {
  public let target: Target
  public let error: any Error

  public var description: String { "\(target.rawValue): \(error)" }
}
