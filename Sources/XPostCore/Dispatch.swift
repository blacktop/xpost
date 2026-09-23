/// Publishes one request to one target.
public typealias Publisher = @Sendable (Request) async throws -> Void

struct Poster: Sendable {
  let target: Target
  let publish: Publisher
}

/// A target that will not receive the post.
struct TargetSkip {
  let target: Target
  let error: any Error

  /// Fatal skips fail the command. A target left out of the default fan-out because it
  /// is not configured is only informational.
  let isFatal: Bool
}

enum DispatchMode: Sendable {
  case publish
  case dryRun
}

/// Builds a poster for every target that is configured. Throws when none is left,
/// carrying every reason, including the ones that are informational otherwise.
func makePosters(
  for selection: TargetSelection, using makePublisher: (Target) throws -> Publisher
) throws -> (posters: [Poster], skips: [TargetSkip]) {
  var posters: [Poster] = []
  var skips: [TargetSkip] = []
  for target in selection.targets {
    do {
      posters.append(Poster(target: target, publish: try makePublisher(target)))
    } catch let error as NotConfigured {
      skips.append(TargetSkip(target: target, error: error, isFatal: selection.isExplicit))
    } catch {
      skips.append(TargetSkip(target: target, error: error, isFatal: true))
    }
  }

  if posters.isEmpty {
    throw PostFailure(
      failures: skips.map { TargetFailure(target: $0.target, error: $0.error) })
  }
  return (posters, skips)
}

/// Validates each target on its own, so a message one network rejects still goes out on
/// the networks that accept it. Returns every failure that should fail the command.
///
/// - Throws: `CancellationError` when the task is cancelled mid-way; the remaining targets
///   are not tried and the interrupted one is not reported as a failure of its own.
func dispatch<Output: TextOutputStream>(
  _ request: Request, to posters: [Poster], skips: [TargetSkip], mode: DispatchMode,
  style: LabelStyle, output: inout Output
) async throws -> [TargetFailure] {
  var ready: [Poster] = []
  var skips = skips
  for poster in posters {
    do {
      try poster.target.validate(request)
      ready.append(poster)
    } catch {
      skips.append(TargetSkip(target: poster.target, error: error, isFatal: true))
    }
  }

  var failures: [TargetFailure] = []
  for skip in skips {
    print("Skipped \(skip.target.styled(style)): \(skipReason(skip.error))", to: &output)
    if skip.isFatal {
      failures.append(TargetFailure(target: skip.target, error: skip.error))
    }
  }

  if ready.isEmpty {
    print("No targets accepted the post", to: &output)
    return failures
  }

  switch mode {
  case .dryRun:
    preview(request, on: ready.map(\.target), style: style, output: &output)
  case .publish:
    failures += try await publish(request, to: ready, style: style, output: &output)
  }
  return failures
}

// Structured errors name their target; the skip line already does.
private func skipReason(_ error: any Error) -> String {
  switch error {
  case let invalid as ValidationError: invalid.reason
  case let unconfigured as NotConfigured: unconfigured.reason
  default: "\(error)"
  }
}

private func preview<Output: TextOutputStream>(
  _ request: Request, on targets: [Target], style: LabelStyle, output: inout Output
) {
  for target in targets {
    let text = quoted(target.preview(request))
    print("[dry-run] would post to \(target.styled(style)): \(text)", to: &output)
  }
  if !request.imagePath.isEmpty {
    print(
      "[dry-run] image: \(request.imagePath) (alt: \(quoted(request.imageAlt)))", to: &output)
  }
}

private func publish<Output: TextOutputStream>(
  _ request: Request, to posters: [Poster], style: LabelStyle, output: inout Output
) async throws -> [TargetFailure] {
  var failures: [TargetFailure] = []
  for poster in posters {
    // Nothing more goes out once the run is interrupted, and a client that reports an
    // interrupted request as its own error does not turn it into a failed target.
    try Task.checkCancellation()
    do {
      try await poster.publish(request)
      try Task.checkCancellation()
      print("Posted to \(poster.target.styled(style))", to: &output)
    } catch {
      try Task.checkCancellation()
      failures.append(TargetFailure(target: poster.target, error: error))
      print("error: \(poster.target.styled(style)): \(error)", to: &output)
    }
  }
  return failures
}
