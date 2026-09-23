import XPostCore

/// Builds the publisher for a target from the process environment.
func makePublisher(
  for target: Target, environment: [String: String], log: RunLog, showsBrowser: Bool
) throws -> Publisher {
  switch target {
  case .bluesky:
    return try blueskyPublisher(
      environment: environment, transport: urlSessionTransport(), log: log)
  case .mastodon:
    return try mastodonPublisher(
      environment: environment, transport: urlSessionTransport(), log: log)
  case .twitter:
    return try makeTwitterPublisher(
      environment: environment, showsBrowser: showsBrowser, log: log)
  }
}
