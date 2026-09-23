import Foundation

/// The targets a run will try, in posting order, and whether the user named them individually.
public struct TargetSelection: Sendable {
  public let targets: [Target]

  /// Individually named targets must be configured. The default fan-out and `all` only
  /// report targets that are not set up.
  public let isExplicit: Bool

  /// Resolves `--target` values, which may repeat and may hold comma-separated lists.
  public init(_ values: [String]) throws {
    let everything = TargetSelection(targets: Target.allCases, isExplicit: false)
    if values.isEmpty {
      self = everything
      return
    }

    var targets: Set<Target> = []
    for value in values.flatMap({ $0.split(separator: ",") }) {
      let name = value.trimmingCharacters(in: .whitespaces).lowercased()
      if name.isEmpty {
        continue
      }
      if name == "all" {
        self = everything
        return
      }
      guard let target = Target(rawValue: name) else {
        throw UsageError("unsupported target \(quoted(name))")
      }
      targets.insert(target)
    }

    if targets.isEmpty {
      throw UsageError("no targets selected")
    }
    self.init(targets: Target.allCases.filter(targets.contains), isExplicit: true)
  }

  private init(targets: [Target], isExplicit: Bool) {
    self.targets = targets
    self.isExplicit = isExplicit
  }
}
