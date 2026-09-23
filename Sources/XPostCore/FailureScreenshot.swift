import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// A fresh path for a screenshot of a failed X page, in a directory only this user can
/// enter. `mkdtemp` reserves it atomically, even when the temporary directory is a shared
/// /tmp; the screenshot shows a signed-in X page.
public func failureScreenshotPath() throws -> String {
  var template = FileManager.default.temporaryDirectory
    .appendingPathComponent("xpost-XXXXXX").path.utf8CString
  let directory = try template.withUnsafeMutableBufferPointer { buffer in
    guard let base = buffer.baseAddress, let result = mkdtemp(base) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return String(cString: result)
  }
  return URL(fileURLWithPath: directory).appendingPathComponent("twitter-failed.png").path
}
