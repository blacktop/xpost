import Foundation

#if canImport(os)
  import os
#endif

/// Messages for the unified log, so a headless run can be read back afterwards:
///
///     log show --last 10m --predicate 'subsystem == "io.blacktop.xpost"'
///
/// Messages are logged as public, so they must never carry credentials. Where there is no
/// unified log, messages only reach stderr.
public struct RunLog: Sendable {
  #if canImport(os)
    private let logger: Logger
  #endif
  private let isVerbose: Bool

  public init(category: String, isVerbose: Bool) {
    #if canImport(os)
      self.logger = Logger(subsystem: "io.blacktop.xpost", category: category)
    #endif
    self.isVerbose = isVerbose
  }

  /// Step-by-step detail: the system log, and stderr when the user asked for it.
  public func note(_ message: String) {
    record(message)
    if isVerbose {
      writeToStderr(message)
    }
  }

  /// Outcomes and instructions the person running the command needs: stderr and the log.
  public func report(_ message: String) {
    record(message)
    writeToStderr(message)
  }

  private func record(_ message: String) {
    #if canImport(os)
      logger.notice("\(message, privacy: .public)")
    #endif
  }

  private func writeToStderr(_ message: String) {
    FileHandle.standardError.write(Data("xpost: \(message)\n".utf8))
  }
}
