import Synchronization

@testable import XPostCore

struct FakeFailure: Error, CustomStringConvertible {
  let description: String
}

/// Records what was published where, in order.
final class Recorder: Sendable {
  private let posts = Mutex<[(target: Target, request: Request)]>([])

  var published: [Target] { posts.withLock { $0.map(\.target) } }
  var requests: [Request] { posts.withLock { $0.map(\.request) } }

  func publisher(for target: Target, failingWith failure: FakeFailure? = nil) -> Publisher {
    { request in
      self.posts.withLock { $0.append((target, request)) }
      if let failure {
        throw failure
      }
    }
  }

  func poster(_ target: Target, failingWith failure: FakeFailure? = nil) -> Poster {
    Poster(target: target, publish: publisher(for: target, failingWith: failure))
  }

  /// Builds recording publishers for `configured` targets; the rest are not configured.
  func makePublisher(configured: Set<Target>) -> @Sendable (Target) throws -> Publisher {
    { target in
      guard configured.contains(target) else {
        throw NotConfigured(target: target, missing: ["XPOST_\(target.rawValue.uppercased())"])
      }
      return self.publisher(for: target)
    }
  }
}
