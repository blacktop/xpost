import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// A child process to run: the program, its arguments, what to write to its stdin, and how
/// long it may take. The input carries credentials; the arguments never do.
public struct HelperInvocation: Sendable {
  public let executable: String
  public let arguments: [String]
  public let input: Data
  public let timeout: TimeInterval
}

public struct HelperOutput: Sendable {
  public let termination: HelperTermination
  public let stdout: Data
  public let stderr: Data
}

/// How a helper process ended.
public enum HelperTermination: Sendable, Equatable {
  /// It exited by itself with this status.
  case exited(Int32)
  /// It outlived its budget and was stopped.
  case timedOut
  /// It wrote more than `helperOutputLimit` bytes to this stream and was stopped.
  case overflowed(stream: String)
}

/// Runs a helper process. Tests substitute a closure that never starts one.
public typealias HelperRunner = @Sendable (HelperInvocation) async throws -> HelperOutput

/// The real runner: Foundation `Process` with pipes, terminated when the budget runs out or
/// the calling task is cancelled.
public func processHelperRunner() -> HelperRunner {
  // A child that dies before reading its stdin would otherwise take xpost down with SIGPIPE;
  // the write reports EPIPE instead.
  signal(SIGPIPE, SIG_IGN)
  return { invocation in try await ChildProcess(invocation).run() }
}

/// One end of a pipe created close-on-exec from the start. Foundation's `Pipe` leaves its
/// descriptors inheritable, so a child spawned on another thread in the meantime would hold
/// them and keep this child's output from ever reaching EOF.
private struct PipeEnds {
  let reading: FileHandle
  let writing: FileHandle

  init() throws {
    var descriptors: [Int32] = [-1, -1]
    #if os(Linux)
      // Glibc's Swift module has no pipe2; a socket pair takes the flag atomically.
      let result = socketpair(
        AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0, &descriptors)
    #else
      // Darwin spawns with POSIX_SPAWN_CLOEXEC_DEFAULT, so setting the flag afterwards is safe.
      let result = pipe(&descriptors)
      for descriptor in descriptors {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      }
    #endif
    guard result == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    reading = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
    writing = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
  }
}

/// `Process` and its pipes are only touched from this class, one call at a time.
private final class ChildProcess: @unchecked Sendable {
  private let process = Process()
  private let stdin: PipeEnds
  private let stdout: OutputCollector
  private let stderr: OutputCollector
  private let invocation: HelperInvocation

  init(_ invocation: HelperInvocation) throws {
    self.invocation = invocation
    stdin = try PipeEnds()
    stdout = OutputCollector(try PipeEnds())
    stderr = OutputCollector(try PipeEnds())
    process.executableURL = URL(fileURLWithPath: invocation.executable)
    process.arguments = invocation.arguments
    process.standardInput = stdin.reading
    process.standardOutput = stdout.pipe.writing
    process.standardError = stderr.pipe.writing
  }

  func run() async throws -> HelperOutput {
    // Weak: a descendant holding a pipe open keeps its reader thread alive past this run.
    stdout.start(onOverflow: { [weak self] in self?.stop() })
    stderr.start(onOverflow: { [weak self] in self?.stop() })
    // Foundation on Linux notices the child's exit only from the run loop of the thread
    // that launched it, so one dedicated thread launches, feeds stdin and waits. The budget
    // covers the request going in too: a child that never reads its stdin does not stall
    // anything here, and once it is gone the write fails instead of blocking.
    let exited = AsyncStream.makeStream(of: Int32.self)
    try await withCheckedThrowingContinuation { (launched: CheckedContinuation<Void, any Error>) in
      let thread = Thread { [self] in
        do {
          try process.run()
        } catch {
          launched.resume(throwing: error)
          return
        }
        launched.resume()
        // The child holds its own ends now; ours would keep its output from ever reaching
        // EOF (Foundation on Linux does not drop them for us).
        try? stdout.pipe.writing.close()
        try? stderr.pipe.writing.close()
        try? stdin.reading.close()
        try? stdin.writing.write(contentsOf: invocation.input)
        try? stdin.writing.close()
        process.waitUntilExit()
        exited.continuation.yield(process.terminationStatus)
        exited.continuation.finish()
      }
      thread.start()
    }

    let timedOut = await withTaskCancellationHandler {
      await waitForExit(exited.stream, within: invocation.timeout)
    } onCancel: {
      stop()
    }
    // A grandchild that survived the child (a browser, say) may keep the pipes open; the
    // child's own output has arrived by now, so take it rather than wait for their EOF.
    let grace: Duration = timedOut ? .seconds(1) : .seconds(5)
    async let out = stdout.finish(within: grace)
    async let err = stderr.finish(within: grace)
    let (stdoutData, stderrData) = await (out, err)
    try Task.checkCancellation()
    let termination: HelperTermination =
      if stdout.overflowed {
        .overflowed(stream: "stdout")
      } else if stderr.overflowed {
        .overflowed(stream: "stderr")
      } else if timedOut {
        .timedOut
      } else {
        .exited(process.terminationStatus)
      }
    return HelperOutput(termination: termination, stdout: stdoutData, stderr: stderrData)
  }

  /// True when the budget ran out and the process had to be stopped.
  private func waitForExit(_ exited: AsyncStream<Int32>, within timeout: TimeInterval) async
    -> Bool
  {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await _ in exited { break }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(timeout))
        return true
      }
      let timedOut = await group.next() ?? false
      group.cancelAll()
      // Whether the budget ran out or the task was cancelled, the child must be gone before
      // its status is read; Foundation traps on the status of a running process.
      if process.isRunning {
        stop()
        process.waitUntilExit()
      }
      return timedOut
    }
  }

  /// SIGTERM, then SIGKILL for a child that ignores it. Both go to the child's process group:
  /// Foundation spawns it as the group leader, and on Linux it does not report the child's
  /// exit until every descendant (the browser, say) is gone too.
  private func stop() {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    if kill(-pid, SIGTERM) != 0 {
      process.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
      if process.isRunning {
        kill(-pid, SIGKILL)
      }
    }
  }
}

/// The most a helper may write to one stream. Its result and diagnostics take a few
/// kilobytes; a child that writes more is broken, and is stopped rather than buffered.
let helperOutputLimit = 1 << 20

/// Gathers one pipe's output as it arrives, so a full pipe never blocks the child. A plain
/// blocking read on a thread of its own: Foundation's readability handler on Linux never
/// reports the end of the stream, and this does.
private final class OutputCollector: @unchecked Sendable {
  let pipe: PipeEnds
  private let lock = NSLock()
  private var data = Data()
  private var reachedEOF = false
  private var passedLimit = false

  init(_ pipe: PipeEnds) {
    self.pipe = pipe
  }

  /// A thread of its own: libdispatch's pool is only a few threads wide on Linux, and a
  /// blocking read parked there starves everything else queued behind it.
  /// Past `helperOutputLimit`, the output is dropped and `onOverflow` runs once; reading
  /// goes on until the end of the stream.
  func start(onOverflow: @escaping @Sendable () -> Void) {
    let descriptor = pipe.reading.fileDescriptor
    let reader = Thread { [self] in
      var buffer = [UInt8](repeating: 0, count: 65536)
      while true {
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
          if keep(buffer[0..<count]) { onOverflow() }
        } else if count < 0 && errno == EINTR {
          continue
        } else {
          lock.withLock { reachedEOF = true }
          return
        }
      }
    }
    reader.start()
  }

  /// Appends `chunk` while the stream is within the limit. True for the chunk that passes it.
  private func keep(_ chunk: ArraySlice<UInt8>) -> Bool {
    lock.withLock {
      guard !passedLimit else { return false }
      guard data.count + chunk.count <= helperOutputLimit else {
        passedLimit = true
        data = Data()
        return true
      }
      data.append(contentsOf: chunk)
      return false
    }
  }

  var overflowed: Bool { lock.withLock { passedLimit } }

  /// Everything read so far: at the end of the stream, or at `grace` after the child
  /// exited when a descendant still holds the pipe open.
  func finish(within grace: Duration) async -> Data {
    let deadline = ContinuousClock.now + grace
    while !lock.withLock({ reachedEOF }), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return lock.withLock { data }
  }
}
