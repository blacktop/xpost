import Foundation

// The contract with helper/src/protocol.ts: one request in, one result out. Keep both in step.

/// What the helper is asked to do.
enum HelperOperation: String, Encodable {
  /// Sign in, verify the account, open the composer, post nothing.
  case check
  case post
}

struct HelperRequest: Encodable {
  let op: HelperOperation
  let baseURL: String
  let username: String
  let password: String?
  let accountID: String
  let stateFile: String?
  let text: String?
  let imagePath: String?
  let timeoutMs: Int
  let screenshotPath: String?
}

enum SessionSource: String, Decodable {
  case state
  case password
}

enum FailureReason: String, Decodable {
  case notSignedIn
  case loginFailed
  case challenge
  case wrongAccount
  case composerUnavailable
  case uploadFailed
  case ambiguous
  case timeout
  case internalError = "internal"
}

/// The helper's verdict. Anything it does not decode as one of these is treated as a crash.
enum HelperResult: Decodable {
  case checked(accountID: String, sessionSource: SessionSource, stateSaved: Bool)
  case posted(accountID: String, sessionSource: SessionSource, stateSaved: Bool, notice: String)
  case failed(reason: FailureReason, detail: String, screenshot: String?)

  private enum CodingKeys: String, CodingKey {
    case outcome, accountID, sessionSource, stateSaved, notice, reason, detail, screenshot
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(String.self, forKey: .outcome) {
    case "checked":
      self = .checked(
        accountID: try values.decode(String.self, forKey: .accountID),
        sessionSource: try values.decode(SessionSource.self, forKey: .sessionSource),
        stateSaved: try values.decode(Bool.self, forKey: .stateSaved))
    case "posted":
      self = .posted(
        accountID: try values.decode(String.self, forKey: .accountID),
        sessionSource: try values.decode(SessionSource.self, forKey: .sessionSource),
        stateSaved: try values.decode(Bool.self, forKey: .stateSaved),
        notice: try values.decode(String.self, forKey: .notice))
    case "failed":
      self = .failed(
        reason: try values.decode(FailureReason.self, forKey: .reason),
        detail: try values.decode(String.self, forKey: .detail),
        screenshot: try values.decodeIfPresent(String.self, forKey: .screenshot))
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .outcome, in: values, debugDescription: "unknown outcome \(other)")
    }
  }
}
