import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct BlueskyConfig: Sendable {
  let handle: String
  let appPassword: String
  let pdsURL: URL

  var pdsLogOrigin: String {
    guard var origin = URLComponents(url: pdsURL, resolvingAgainstBaseURL: false) else {
      return "unknown PDS"
    }
    origin.user = nil
    origin.password = nil
    origin.path = ""
    origin.query = nil
    origin.fragment = nil
    return origin.string ?? "unknown PDS"
  }

  init(environment: [String: String]) throws {
    let missing = ["XPOST_BLUESKY_HANDLE", "XPOST_BLUESKY_APP_PASSWORD"].filter {
      environment.setting($0).isEmpty
    }
    if !missing.isEmpty {
      throw NotConfigured(target: .bluesky, missing: missing)
    }

    let pds = environment.setting("XPOST_BLUESKY_PDS_URL")
    self.handle = environment.setting("XPOST_BLUESKY_HANDLE")
    self.appPassword = environment.setting("XPOST_BLUESKY_APP_PASSWORD")
    self.pdsURL = try serverURL(
      pds.isEmpty ? "https://bsky.social" : pds, from: "XPOST_BLUESKY_PDS_URL")
  }
}

/// Builds the Bluesky publisher from the environment.
///
/// - Throws: `NotConfigured` when the handle or app password is missing, `InvalidSetting`
///   for an unusable PDS URL.
public func blueskyPublisher(
  environment: [String: String], transport: @escaping Transport, log: RunLog
) throws -> Publisher {
  let client = BlueskyClient(
    config: try BlueskyConfig(environment: environment), transport: transport, log: log,
    now: { Date() })
  return { try await client.publish($0) }
}

struct BlueskyClient: Sendable {
  let config: BlueskyConfig
  let transport: Transport
  let log: RunLog
  let now: @Sendable () -> Date

  /// Logs in, uploads the image if there is one, then creates the post record.
  func publish(_ request: Request) async throws {
    log.note("bluesky: logging in to \(config.pdsLogOrigin) as \(config.handle)")
    let session: Session = try await call(
      "login", method: "com.atproto.server.createSession", token: nil,
      body: try JSONEncoder().encode(Login(identifier: config.handle, password: config.appPassword))
    )

    var embed: ImagesEmbed?
    if !request.imagePath.isEmpty {
      let blob = try await uploadImage(at: request.imagePath, token: session.accessJwt)
      embed = ImagesEmbed(images: [.init(alt: request.imageAlt, image: blob)])
    }

    let (text, facets) = renderBlueskyPost(request.text)
    let record = PostRecord(
      text: text, createdAt: now().formatted(.iso8601),
      facets: facets.isEmpty ? nil : facets.map(Facet.init), embed: embed)
    log.note("bluesky: creating record with \(facets.count) link facet(s)")
    let _: CreatedRecord = try await call(
      "create record", method: "com.atproto.repo.createRecord", token: session.accessJwt,
      body: try JSONEncoder().encode(
        CreateRecord(repo: session.did, collection: "app.bsky.feed.post", record: record)))
  }

  private func uploadImage(at path: String, token: String) async throws -> BlobRef {
    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw StepError(step: "read image", underlying: Failure(error.localizedDescription))
    }

    // The PDS stores the declared type with the blob, so send the real one.
    let mimeType = imageMIMEType(forExtension: url.pathExtension)
    log.note("bluesky: uploading \(path) (\(mimeType), \(data.count) bytes)")
    let uploaded: UploadedBlob = try await call(
      "upload blob", method: "com.atproto.repo.uploadBlob", token: token, body: data,
      contentType: mimeType)
    return uploaded.blob
  }

  private func call<Response: Decodable>(
    _ step: String, method: String, token: String?, body: Data,
    contentType: String = "application/json"
  ) async throws -> Response {
    var request = URLRequest(url: config.pdsURL.appending(path: "xrpc/\(method)"))
    request.httpMethod = "POST"
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue("xpost", forHTTPHeaderField: "User-Agent")
    if let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      let (data, response) = try await transport(request, body)
      guard (200..<300).contains(response.statusCode) else {
        throw HTTPStatusError(status: response.statusCode, detail: xrpcErrorDetail(data))
      }
      return try JSONDecoder().decode(Response.self, from: data)
    } catch let error as DecodingError {
      throw StepError(
        step: step, underlying: Failure("unexpected response: \(error.localizedDescription)"))
    } catch {
      throw StepError(step: step, underlying: error)
    }
  }
}

/// XRPC errors are `{"error": "Name", "message": "text"}`; either field may be absent.
private func xrpcErrorDetail(_ data: Data) -> String {
  struct XRPCError: Decodable {
    let error: String?
    let message: String?
  }
  guard let body = try? JSONDecoder().decode(XRPCError.self, from: data) else {
    return ""
  }
  return [body.error, body.message].compactMap(\.self).joined(separator: ": ")
}

private struct Login: Encodable {
  let identifier: String
  let password: String
}

private struct Session: Decodable {
  let accessJwt: String
  let did: String
}

private struct UploadedBlob: Decodable {
  let blob: BlobRef
}

private struct CreatedRecord: Decodable {
  let uri: String
}

/// A blob reference, passed from uploadBlob into the record unchanged.
struct BlobRef: Codable {
  struct Link: Codable {
    let link: String

    enum CodingKeys: String, CodingKey {
      case link = "$link"
    }
  }

  let type: String
  let ref: Link
  let mimeType: String
  let size: Int

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case ref, mimeType, size
  }
}

private struct CreateRecord: Encodable {
  let repo: String
  let collection: String
  let record: PostRecord
}

private struct PostRecord: Encodable {
  let type = "app.bsky.feed.post"
  let text: String
  let createdAt: String
  let facets: [Facet]?
  let embed: ImagesEmbed?

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case text, createdAt, facets, embed
  }
}

private struct Facet: Encodable {
  struct ByteSlice: Encodable {
    let byteStart: Int
    let byteEnd: Int
  }

  struct Link: Encodable {
    let type = "app.bsky.richtext.facet#link"
    let uri: String

    enum CodingKeys: String, CodingKey {
      case type = "$type"
      case uri
    }
  }

  let index: ByteSlice
  let features: [Link]

  init(_ facet: BlueskyLinkFacet) {
    index = ByteSlice(byteStart: facet.byteStart, byteEnd: facet.byteEnd)
    features = [Link(uri: facet.uri)]
  }
}

private struct ImagesEmbed: Encodable {
  struct Image: Encodable {
    let alt: String
    let image: BlobRef
  }

  let type = "app.bsky.embed.images"
  let images: [Image]

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case images
  }
}
