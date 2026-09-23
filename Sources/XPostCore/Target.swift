/// A social network xpost can publish to. Cases are declared in the order posts go out.
public enum Target: String, CaseIterable, Sendable {
  case bluesky
  case mastodon
  case twitter

  /// Checks the request against the target's length limit without any network access.
  public func validate(_ request: Request) throws {
    let (count, limit, unit) = measure(request)
    guard count <= limit else {
      throw ValidationError(
        target: self, reason: "message too long: \(count) \(unit) (max \(limit))")
    }
  }

  /// The text the target would carry for this request.
  public func preview(_ request: Request) -> String {
    switch self {
    case .bluesky: renderBlueskyPost(request.text).text
    case .mastodon, .twitter: request.text
    }
  }

  // Bluesky counts graphemes of the text with links already shortened, which is
  // what the post carries. Mastodon and X count unicode scalars of the full text.
  private func measure(_ request: Request) -> (count: Int, limit: Int, unit: String) {
    switch self {
    case .bluesky: (preview(request).count, 300, "graphemes")
    case .mastodon: (request.text.unicodeScalars.count, 500, "characters")
    case .twitter: (request.text.unicodeScalars.count, 280, "characters")
    }
  }
}

/// How target names are rendered in command output.
public enum LabelStyle: Sendable {
  case plain
  case ansi
}

extension Target {
  private var label: String {
    switch self {
    case .bluesky: "\u{e28e} Bluesky"
    case .mastodon: "\u{edc0} Mastodon"
    case .twitter: "\u{f099} Twitter/X"
    }
  }

  private var color: String {
    switch self {
    case .bluesky: "\u{1B}[38;5;45m"
    case .mastodon: "\u{1B}[38;5;63m"
    case .twitter: "\u{1B}[38;5;39m"
    }
  }

  /// The Nerd Font icon and display name, colored when the style asks for it.
  func styled(_ style: LabelStyle) -> String {
    switch style {
    case .plain: label
    case .ansi: color + label + "\u{1B}[0m"
    }
  }
}
