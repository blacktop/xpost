import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Sends one HTTP request with an optional body and returns the response. Clients take
/// this as a parameter so tests can stand in for the network.
public typealias Transport =
  @Sendable (URLRequest, Data?) async throws -> (Data, HTTPURLResponse)

/// A response with a status code the client does not accept.
struct HTTPStatusError: Error, Equatable, CustomStringConvertible {
  let status: Int
  let detail: String

  var description: String {
    detail.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(detail)"
  }
}

/// A failure described only by its message, such as a malformed body.
public struct Failure: Error, Equatable, CustomStringConvertible {
  public let description: String

  public init(_ description: String) {
    self.description = description
  }
}

/// A request that got no response: the connection failed or timed out, so whether the
/// server acted on it is unknown.
struct NetworkFailure: Error, Equatable, CustomStringConvertible {
  let description: String
}

/// A failure in one named step of a publish, such as "login" or "create record".
struct StepError: Error, CustomStringConvertible {
  let step: String
  let underlying: any Error

  var description: String { "\(step): \(underlying)" }
}

/// A transport backed by URLSession that keeps no cookies or cache between runs. The timeout
/// bounds the whole exchange, not just the gaps between bytes, so a stalled server cannot
/// hold a run open.
public func urlSessionTransport() -> Transport {
  let timeout: TimeInterval = 30
  let configuration = URLSessionConfiguration.ephemeral
  configuration.timeoutIntervalForRequest = timeout
  configuration.timeoutIntervalForResource = timeout
  let session = URLSession(configuration: configuration)

  return { request, body in
    let data: Data
    let response: URLResponse
    do {
      (data, response) =
        if let body {
          try await session.upload(for: request, from: body)
        } else {
          try await session.data(for: request)
        }
    } catch {
      // URLSession reports an interrupt as a network error; it is not one.
      if Task.isCancelled {
        throw CancellationError()
      }
      // URLSession errors print as raw NSError dumps; keep the sentence meant for people.
      throw NetworkFailure(description: error.localizedDescription)
    }
    guard let response = response as? HTTPURLResponse else {
      throw Failure("response is not HTTP")
    }
    return (data, response)
  }
}
