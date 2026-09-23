import Foundation

/// A multipart/form-data body with text fields and one file part.
struct MultipartForm {
  struct FilePart {
    let name: String
    let filename: String
    let mimeType: String
    let data: Data
  }

  let boundary: String
  let fields: [(name: String, value: String)]
  let file: FilePart

  init(
    fields: [(name: String, value: String)], file: FilePart, boundary: String = UUID().uuidString
  ) {
    self.fields = fields
    self.file = file
    self.boundary = boundary
  }

  var contentType: String { "multipart/form-data; boundary=\(boundary)" }

  var body: Data {
    var data = Data()
    for (name, value) in fields {
      data += Data("--\(boundary)\r\n".utf8)
      data += Data("Content-Disposition: form-data; name=\"\(escaped(name))\"\r\n\r\n".utf8)
      data += Data("\(value)\r\n".utf8)
    }
    data += Data("--\(boundary)\r\n".utf8)
    data += Data(
      ("Content-Disposition: form-data; name=\"\(escaped(file.name))\"; "
        + "filename=\"\(escaped(file.filename))\"\r\n").utf8)
    data += Data("Content-Type: \(file.mimeType)\r\n\r\n".utf8)
    data += file.data
    data += Data("\r\n--\(boundary)--\r\n".utf8)
    return data
  }

  // Quoted names follow RFC 7578: percent-encode the characters that would end the quote.
  // Done per scalar because "\r\n" is one Character and would not match "\r" alone.
  private func escaped(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\r": result += "%0D"
      case "\n": result += "%0A"
      case "\"": result += "%22"
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}
