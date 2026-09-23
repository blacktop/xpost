import XPostCore

// The one place the executable chooses how X is reached.

#if os(macOS)
  import XPostTwitter

  func makeTwitterPublisher(
    environment: [String: String], showsBrowser: Bool, log: RunLog
  ) throws -> Publisher {
    try twitterPublisher(
      environment: environment, store: .default, showsWindow: showsBrowser, log: log)
  }

  /// WebKit and Touch ID need the AppKit loop; nothing else does. Only a run that will really
  /// post to X pays for it: a bad --target or missing X setup is reported by post() itself.
  func mainLoop(
    forPostingTo targets: [String], dryRun: Bool, showsBrowser: Bool,
    environment: [String: String]
  ) -> MainLoop {
    guard !dryRun, (try? TargetSelection(targets))?.targets.contains(.twitter) == true,
      (try? TwitterConfig(environment: environment, store: .default)) != nil
    else {
      return .dispatch
    }
    return .appKit(showsWindow: showsBrowser)
  }
#else
  import XPostChromium

  /// Everywhere else X is reached through headless Chromium, driven by the helper under
  /// helper/ in a child process. The browser window flag has nothing to show.
  func makeTwitterPublisher(
    environment: [String: String], showsBrowser: Bool, log: RunLog
  ) throws -> Publisher {
    try chromiumPublisher(environment: environment, runner: processHelperRunner(), log: log)
  }

  func mainLoop(
    forPostingTo targets: [String], dryRun: Bool, showsBrowser: Bool,
    environment: [String: String]
  ) -> MainLoop {
    .dispatch
  }
#endif
