import Foundation

/// A link annotation over a UTF-8 byte range of the rendered post text.
struct BlueskyLinkFacet: Equatable, Sendable {
  let byteStart: Int
  let byteEnd: Int
  let uri: String
}

// Link display limits mirror the Bluesky composer: a path longer than
// maxPathDisplay is cut to pathTruncateAt characters plus an ellipsis.
private let maxPathDisplay = 15
private let pathTruncateAt = 13

/// Rewrites every URL in `text` to its short display form and returns the rewritten text
/// along with facets pointing at the full URLs. Only the short label occupies the post
/// body, so a long URL costs a handful of graphemes against the limit instead of its
/// full length.
func renderBlueskyPost(_ text: String) -> (text: String, facets: [BlueskyLinkFacet]) {
  // ASCII whitespace only, matched by scalar, so URL boundaries do not depend on
  // grapheme clustering with the characters around them.
  let urlPattern = /https?:\/\/[^\t\n\u{0C}\r ]+/.matchingSemantics(.unicodeScalar)

  var body = ""
  var facets: [BlueskyLinkFacet] = []
  var cursor = text.startIndex

  for match in text.matches(of: urlPattern) {
    let (link, trailing) = splitTrailingPunctuation(text[match.range])
    if link.isEmpty {
      continue
    }

    body += text[cursor..<match.range.lowerBound]
    let start = body.utf8.count
    body += shortenURL(String(link))
    facets.append(
      BlueskyLinkFacet(byteStart: start, byteEnd: body.utf8.count, uri: String(link)))

    body += trailing
    cursor = match.range.upperBound
  }

  if facets.isEmpty {
    return (text, [])
  }
  body += text[cursor...]
  return (body, facets)
}

/// Peels sentence punctuation off a matched URL so that "see https://example.com/page."
/// links the page and leaves the period as text.
func splitTrailingPunctuation(_ match: Substring) -> (link: Substring, trailing: Substring) {
  let scalars = match.unicodeScalars
  var excessClosing = scalars.count { $0 == ")" } - scalars.count { $0 == "(" }
  var end = scalars.endIndex

  while end > scalars.startIndex {
    let last = scalars[scalars.index(before: end)]
    switch last {
    case ".", ",", ";", "!", "?":
      break
    case ")" where excessClosing > 0:
      excessClosing -= 1
    default:
      return (match[..<end], match[end...])
    }
    end = scalars.index(before: end)
  }
  return (match[..<end], match[end...])
}

/// Renders a URL the way the Bluesky composer does: drop the scheme and truncate a long
/// path. Mirrors toShortUrl in bluesky-social/social-app.
func shortenURL(_ raw: String) -> String {
  guard let parts = URLComponents(string: raw), let host = parts.host,
    parts.scheme == "http" || parts.scheme == "https"
  else {
    return raw
  }

  var path = parts.percentEncodedPath
  if path == "/" {
    path = ""
  }
  if let query = parts.percentEncodedQuery, !query.isEmpty {
    path += "?" + query
  }
  if let fragment = parts.percentEncodedFragment, !fragment.isEmpty {
    path += "#" + fragment
  }

  let authority = parts.port.map { "\(host):\($0)" } ?? host
  if path.unicodeScalars.count > maxPathDisplay {
    return authority + String(path.unicodeScalars.prefix(pathTruncateAt)) + "..."
  }
  return authority + path
}
