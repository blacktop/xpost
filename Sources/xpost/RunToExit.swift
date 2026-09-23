import Dispatch
import Foundation

#if os(macOS)
  import AppKit
#endif

/// Which main run loop a command needs while its async work runs.
enum MainLoop {
  /// Enough for network clients and child processes.
  case dispatch
  /// Required by WebKit and Touch ID on macOS. `showsWindow` makes xpost a regular app with
  /// a Dock icon; otherwise it stays an accessory that can still come to the front for prompts.
  case appKit(showsWindow: Bool)
}

/// Runs `body` on the main actor, then exits the process with its outcome.
///
/// Commands stay synchronous and enter async code here because `AsyncParsableCommand`
/// occupies the main actor, which starves it once a nested run loop has to take over.
/// Ctrl-C and SIGTERM cancel the work and wait for it to unwind, so a child process
/// (the X helper) is stopped before xpost is gone rather than left to finish the post.
func runToExit(_ loop: MainLoop, _ body: @escaping @MainActor @Sendable () async throws -> Void) {
  let work = Task { @MainActor in try await body() }
  Task { @MainActor in
    do {
      try await work.value
      XPost.exit()
    } catch is CancellationError {
      FileHandle.standardError.write(Data("xpost: interrupted\n".utf8))
      exit(130)
    } catch {
      XPost.exit(withError: error)
    }
  }
  let interrupts = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler { work.cancel() }
    source.resume()
    return source
  }

  withExtendedLifetime(interrupts) {
    switch loop {
    case .dispatch:
      dispatchMain()
    case .appKit(let showsWindow):
      #if os(macOS)
        // Commands run on the main thread; ArgumentParser just does not say so in the types.
        MainActor.assumeIsolated {
          let app = NSApplication.shared
          app.setActivationPolicy(showsWindow ? .regular : .accessory)
          app.run()
        }
      #else
        _ = showsWindow
        dispatchMain()
      #endif
    }
  }
}
