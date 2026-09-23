import Foundation
import Synchronization
import Testing

@testable import XPostCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

let testLog = RunLog(category: "test", isVerbose: false)

/// A three-byte file in the temporary directory; the caller removes it.
func temporaryImage(named name: String = "image.png") throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("xpost-\(UUID().uuidString)-\(name)")
  try Data([1, 2, 3]).write(to: url)
  return url
}

/// Answers requests from a queue of canned responses and records what was sent.
final class TransportStub: Sendable {
  struct Sent {
    let request: URLRequest
    let body: Data?

    var path: String { request.url?.path() ?? "" }

    func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }

    /// The body parsed as a JSON object, compared as NSDictionary for readable diffs.
    func json() throws -> NSDictionary {
      try #require(try JSONSerialization.jsonObject(with: body ?? Data()) as? NSDictionary)
    }
  }

  enum Reply {
    case status(Int, String)
    case failure(NetworkFailure)
  }

  private let state: Mutex<(replies: [Reply], sent: [Sent])>

  init(_ replies: [Reply]) {
    state = Mutex((replies, []))
  }

  var sent: [Sent] { state.withLock { $0.sent } }

  var transport: Transport {
    { request, body in
      let reply = self.state.withLock { state -> Reply? in
        state.sent.append(Sent(request: request, body: body))
        return state.replies.isEmpty ? nil : state.replies.removeFirst()
      }
      switch reply {
      case .status(let code, let json):
        let url = try #require(request.url)
        let response = try #require(
          HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil))
        return (Data(json.utf8), response)
      case .failure(let failure):
        throw failure
      case nil:
        throw Failure("unexpected request to \(request.url?.absoluteString ?? "nil")")
      }
    }
  }
}
