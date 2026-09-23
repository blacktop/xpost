/// Wraps `text` in double quotes with backslash escapes, so a multi-line post previews on
/// one line. Escapes follow Go's %q, which the output format comes from; printable
/// characters, including emoji, are kept as they are.
func quoted(_ text: String) -> String {
  var result = "\""
  for scalar in text.unicodeScalars {
    switch scalar {
    case "\"": result += "\\\""
    case "\\": result += "\\\\"
    case "\n": result += "\\n"
    case "\r": result += "\\r"
    case "\t": result += "\\t"
    case "\u{07}": result += "\\a"
    case "\u{08}": result += "\\b"
    case "\u{0B}": result += "\\v"
    case "\u{0C}": result += "\\f"
    case "\u{00}"..."\u{1F}", "\u{7F}":
      let hex = String(scalar.value, radix: 16)
      result += "\\x" + (hex.count < 2 ? "0" + hex : hex)
    default: result.unicodeScalars.append(scalar)
    }
  }
  return result + "\""
}
