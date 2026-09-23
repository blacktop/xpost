import Foundation
import Synchronization

/// Picks the message from the positional argument, `--message`, or piped stdin, in that
/// order. `readStdin` returns nil when stdin is a terminal.
func resolveMessage(
  argument: String?, option: String?, readStdin: () async throws -> String?
) async throws -> String {
  let argument = argument ?? ""
  let option = option ?? ""
  if !argument.isEmpty && !option.isEmpty {
    throw UsageError("provide the message either as an argument or with --message, not both")
  }

  let given = argument.isEmpty ? option : argument
  let message = given.isEmpty ? try await readStdin() ?? "" : given
  let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty {
    throw UsageError("message is required")
  }
  return trimmed
}

/// Everything piped into `handle`, or nil when it is a terminal. The read blocks a
/// background thread, so an interrupt does not wait for the writer: cancellation throws
/// at once and whatever arrives afterwards is dropped.
public func readPipedInput(from handle: FileHandle) async throws -> String? {
  if isatty(handle.fileDescriptor) != 0 {
    return nil
  }
  let pending = Mutex(
    (continuation: Optional<CheckedContinuation<Data, any Error>>.none, cancelled: false))
  let data = try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      let cancelled = pending.withLock { state in
        if state.cancelled { return true }
        state.continuation = continuation
        return false
      }
      guard !cancelled else {
        continuation.resume(throwing: CancellationError())
        return
      }
      DispatchQueue.global().async {
        let data = handle.readDataToEndOfFile()
        let waiting = pending.withLock { state in
          defer { state.continuation = nil }
          return state.continuation
        }
        waiting?.resume(returning: data)
      }
    }
  } onCancel: {
    let waiting = pending.withLock { state in
      state.cancelled = true
      defer { state.continuation = nil }
      return state.continuation
    }
    waiting?.resume(throwing: CancellationError())
  }
  try Task.checkCancellation()
  return String(decoding: data, as: UTF8.self)
}
