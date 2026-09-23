import Foundation
import Testing

@testable import XPostCore

@Suite struct MultipartTests {
  @Test func encodesFieldsThenTheFile() {
    let form = MultipartForm(
      fields: [("description", "a chart\nline two")],
      file: .init(name: "file", filename: "shot.png", mimeType: "image/png", data: Data([0, 1])),
      boundary: "B")

    #expect(form.contentType == "multipart/form-data; boundary=B")
    let want = """
      --B\r
      Content-Disposition: form-data; name="description"\r
      \r
      a chart
      line two\r
      --B\r
      Content-Disposition: form-data; name="file"; filename="shot.png"\r
      Content-Type: image/png\r
      \r
      \u{0}\u{1}\r
      --B--\r

      """
    #expect(form.body == Data(want.utf8))
  }

  @Test func escapesQuotesAndLineBreaksInNames() {
    let form = MultipartForm(
      fields: [],
      file: .init(name: "file", filename: "a\"b\r\n.png", mimeType: "image/png", data: Data()),
      boundary: "B")

    let body = String(decoding: form.body, as: UTF8.self)
    #expect(body.contains("filename=\"a%22b%0D%0A.png\""))
  }

  @Test func usesAFreshBoundaryByDefault() {
    let file = MultipartForm.FilePart(name: "f", filename: "f", mimeType: "x/y", data: Data())

    #expect(
      MultipartForm(fields: [], file: file).boundary
        != MultipartForm(fields: [], file: file).boundary)
  }
}
