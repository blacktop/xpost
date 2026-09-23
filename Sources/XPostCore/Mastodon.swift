import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct MastodonConfig: Sendable {
  let server: URL
  let accessToken: String

  init(environment: [String: String]) throws {
    let missing = ["XPOST_MASTODON_SERVER", "XPOST_MASTODON_ACCESS_TOKEN"].filter {
      environment.setting($0).isEmpty
    }
    if !missing.isEmpty {
      throw NotConfigured(target: .mastodon, missing: missing)
    }

    self.server = try serverURL(
      environment.setting("XPOST_MASTODON_SERVER"), from: "XPOST_MASTODON_SERVER")
    self.accessToken = environment.setting("XPOST_MASTODON_ACCESS_TOKEN")
  }
}

/// Builds the Mastodon publisher from the environment.
///
/// - Throws: `NotConfigured` when the server or token is missing, `InvalidSetting` for an
///   unusable server URL.
public func mastodonPublisher(
  environment: [String: String], transport: @escaping Transport, log: RunLog
) throws -> Publisher {
  let client = MastodonClient(
    config: try MastodonConfig(environment: environment), transport: transport, log: log)
  return { try await client.publish($0) }
}

struct MastodonClient: Sendable {
  let config: MastodonConfig
  let transport: Transport
  let log: RunLog
  var mediaProcessingTimeout: Duration = .seconds(30)
  var mediaPollInterval: Duration = .seconds(1)
  /// The wait before the first retry of the post; the second retry waits twice as long.
  var retryDelay: Duration = .seconds(2)
  static let postAttempts = 3

  /// Uploads the image if there is one, then posts the status.
  ///
  /// The upload is never retried. The post is retried on gateway errors and network
  /// failures, always with the same Idempotency-Key. Mastodon answers a repeated key with
  /// the post the first request made, so a retry cannot post twice.
  func publish(_ request: Request) async throws {
    var mediaIDs: [String] = []
    if !request.imagePath.isEmpty {
      mediaIDs.append(try await uploadMedia(at: request.imagePath, description: request.imageAlt))
    }

    log.note("mastodon: posting status with \(mediaIDs.count) attachment(s)")
    let status = Status(status: request.text, mediaIds: mediaIDs.isEmpty ? nil : mediaIDs)
    let _: (Posted, Int) = try await call(
      "post status", path: "api/v1/statuses", body: try JSONEncoder().encode(status),
      contentType: "application/json", idempotencyKey: UUID().uuidString)
  }

  private func uploadMedia(at path: String, description: String) async throws -> String {
    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw StepError(step: "read image", underlying: Failure(error.localizedDescription))
    }

    let mimeType = imageMIMEType(forExtension: url.pathExtension)
    let form = MultipartForm(
      fields: description.isEmpty ? [] : [("description", description)],
      file: .init(name: "file", filename: url.lastPathComponent, mimeType: mimeType, data: data))
    log.note("mastodon: uploading \(path) (\(mimeType), \(data.count) bytes)")
    let (attachment, status): (Attachment, Int) = try await call(
      "upload media", path: "api/v2/media", body: form.body, contentType: form.contentType)
    if status == 202 {
      try await waitForMedia(attachment.id)
    }
    return attachment.id
  }

  private func waitForMedia(_ id: String) async throws {
    let step = "process media"
    let url = config.server.appending(path: "api/v1/media").appending(component: id)
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          while true {
            try Task.checkCancellation()
            let (data, status) = try await send(url: url, method: "GET")
            try Task.checkCancellation()
            if status == 200 { return }
            guard status == 206 else {
              throw HTTPStatusError(status: status, detail: mastodonErrorDetail(data))
            }
            try await Task.sleep(for: mediaPollInterval)
          }
        }
        group.addTask {
          try await Task.sleep(for: mediaProcessingTimeout)
          throw Failure("media processing timed out")
        }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
    } catch {
      throw StepError(step: step, underlying: error)
    }
  }

  private func call<Response: Decodable>(
    _ step: String, path: String, body: Data, contentType: String,
    idempotencyKey: String? = nil
  ) async throws -> (Response, Int) {
    let url = config.server.appending(path: path)
    do {
      let (data, status) =
        if let idempotencyKey {
          try await sendRetrying(
            url: url, body: body, contentType: contentType, idempotencyKey: idempotencyKey)
        } else {
          try await send(url: url, body: body, contentType: contentType)
        }
      return (try JSONDecoder().decode(Response.self, from: data), status)
    } catch let error as DecodingError {
      throw StepError(
        step: step, underlying: Failure("unexpected response: \(error.localizedDescription)"))
    } catch {
      throw StepError(step: step, underlying: error)
    }
  }

  private func send(
    url: URL, method: String = "POST", body: Data? = nil, contentType: String? = nil,
    idempotencyKey: String? = nil
  ) async throws -> (Data, Int) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(config.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("xpost", forHTTPHeaderField: "User-Agent")
    request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")

    let (data, response) = try await transport(request, body)
    guard (200..<300).contains(response.statusCode) else {
      throw HTTPStatusError(status: response.statusCode, detail: mastodonErrorDetail(data))
    }
    return (data, response.statusCode)
  }

  /// Sends a write that carries an Idempotency-Key, retrying when it cannot tell whether
  /// Mastodon saw the request: a gateway error or a network failure.
  private func sendRetrying(
    url: URL, body: Data, contentType: String, idempotencyKey: String
  ) async throws -> (Data, Int) {
    var attempt = 1
    while true {
      do {
        return try await send(
          url: url, body: body, contentType: contentType, idempotencyKey: idempotencyKey)
      } catch let error where isGatewayOrNetworkFailure(error) {
        // Cancellation can race a received HTTP error, not just a URLSession failure.
        try Task.checkCancellation()
        guard attempt < Self.postAttempts else {
          throw Failure(
            "\(error) (\(attempt) attempts; the post may have gone out, check before rerunning)")
        }
        let delay = retryDelay * attempt
        log.note("mastodon: \(error); retrying in \(delay)")
        try await Task.sleep(for: delay)
        attempt += 1
      }
    }
  }
}

/// A 502, 503 or 504 comes from a proxy in front of Mastodon, or from Mastodon while another
/// request holds the post's idempotency lock.
private func isGatewayOrNetworkFailure(_ error: any Error) -> Bool {
  switch error {
  case let http as HTTPStatusError: [502, 503, 504].contains(http.status)
  case is NetworkFailure: true
  default: false
  }
}

/// Mastodon errors are `{"error": "text"}`, sometimes with `error_description`.
private func mastodonErrorDetail(_ data: Data) -> String {
  struct APIError: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
      case error
      case errorDescription = "error_description"
    }
  }
  guard let body = try? JSONDecoder().decode(APIError.self, from: data) else {
    return ""
  }
  return [body.error, body.errorDescription].compactMap(\.self).joined(separator: ": ")
}

private struct Status: Encodable {
  let status: String
  let mediaIds: [String]?

  enum CodingKeys: String, CodingKey {
    case status
    case mediaIds = "media_ids"
  }
}

private struct Attachment: Decodable {
  let id: String
}

private struct Posted: Decodable {
  let id: String
}
