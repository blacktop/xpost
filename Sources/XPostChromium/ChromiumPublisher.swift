import Foundation
import XPostCore

/// The whole run, sign-in included; the helper gets a little less so it can answer first.
let helperBudget: TimeInterval = 180

/// Builds the X publisher that posts through the Chromium helper.
public func chromiumPublisher(
  environment: [String: String], runner: @escaping HelperRunner, log: RunLog
) throws -> Publisher {
  let config = try ChromiumConfig(environment: environment)
  return { request in
    if !request.imagePath.isEmpty {
      log.report("alt text is not applied on X")
    }
    let result = try await runHelper(
      config: config, op: .post, text: request.text,
      imagePath: request.imagePath.isEmpty ? nil : request.imagePath, runner: runner, log: log)
    guard case .posted(let accountID, let source, _, let notice) = result else {
      throw Failure("helper answered a post with \(result)")
    }
    log.note("posted as X user id \(accountID) via \(source.rawValue) session; X said: \(notice)")
  }
}

/// `xpost twitter check`: signs in, verifies the account and opens the composer. Posts nothing.
public func chromiumCheck(
  environment: [String: String], runner: @escaping HelperRunner, log: RunLog
) async throws -> String {
  let config = try ChromiumConfig(environment: environment)
  let result = try await runHelper(
    config: config, op: .check, text: nil, imagePath: nil, runner: runner, log: log)
  guard case .checked(let accountID, let source, let stateSaved) = result else {
    throw Failure("helper answered a check with \(result)")
  }
  let saved = stateSaved ? "; session state saved" : ""
  return "X account \(accountID) verified via \(source.rawValue) session; composer opened\(saved)"
}

/// A failure the helper reported. `screenshot` is where it left the page for inspection.
public struct HelperFailure: Error, CustomStringConvertible {
  public let reason: String
  public let detail: String
  public let screenshot: String?

  public var description: String {
    let at = screenshot.map { " (screenshot: \($0))" } ?? ""
    return "\(reason): \(detail)\(at)"
  }
}

private func runHelper(
  config: ChromiumConfig, op: HelperOperation, text: String?, imagePath: String?,
  runner: HelperRunner, log: RunLog
) async throws -> HelperResult {
  let screenshot = try failureScreenshotPath()
  // Only a failure leaves a screenshot; empty directories would pile up in $TMPDIR.
  defer {
    if !FileManager.default.fileExists(atPath: screenshot) {
      try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: screenshot).deletingLastPathComponent())
    }
  }
  let request = HelperRequest(
    op: op, baseURL: config.baseURL, username: config.user, password: config.password,
    accountID: config.accountID, stateFile: config.stateFile, text: text, imagePath: imagePath,
    timeoutMs: Int((helperBudget - 10) * 1000), screenshotPath: screenshot)
  let invocation = HelperInvocation(
    executable: "/usr/bin/env", arguments: ["node", config.helperScript],
    input: try JSONEncoder().encode(request), timeout: helperBudget)

  log.note("running the X helper (\(op.rawValue)) as \(config.user)")
  // One run, whatever it reports: an uncertain outcome is never retried, since the post may
  // have gone out.
  let output = try await runner(invocation)
  for line in String(decoding: output.stderr, as: UTF8.self).split(separator: "\n") {
    log.note("helper: \(line)")
  }
  switch output.termination {
  case .exited(0):
    break
  case .exited(let status):
    let last = String(decoding: output.stderr, as: UTF8.self).split(separator: "\n").last ?? ""
    throw Failure("helper exited with status \(status): \(last)")
  case .timedOut:
    throw Failure("helper did not finish within \(Int(helperBudget))s and was stopped")
  case .overflowed(let stream):
    throw Failure(
      "helper wrote more than \(helperOutputLimit / 1024) KiB to \(stream) and was stopped")
  }
  let result: HelperResult
  do {
    result = try JSONDecoder().decode(HelperResult.self, from: output.stdout)
  } catch {
    throw Failure("helper returned an unreadable result: \(error)")
  }
  if case .failed(let reason, let detail, let screenshot) = result {
    if let screenshot {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: screenshot)
    }
    throw HelperFailure(reason: reason.rawValue, detail: detail, screenshot: screenshot)
  }
  return result
}
