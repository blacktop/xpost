import ArgumentParser
import Foundation
import XPostCore

#if os(macOS)
  import XPostTwitter

  struct Twitter: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Manage the X (Twitter) passkey and saved session",
      discussion: """
        Posting to X signs in with a passkey that xpost keeps in this Mac's Secure Enclave and \
        unlocks with Touch ID. Enroll it once, then set XPOST_TWITTER_USER to your X username.
        """,
      subcommands: [Enroll.self, Logout.self, Probe.self, ExportSession.self]
    )
  }

  extension Twitter {
    struct ExportSession: ParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Sign in manually and export a session for the Linux helper (no post)")

      @Option(help: "New Playwright session file to write with owner-only permissions")
      var output: String

      @OptionGroup var verbosity: Verbosity

      func run() {
        let accountID = ProcessInfo.processInfo.environment.setting("XPOST_TWITTER_ACCOUNT_ID")
        let destination = URL(fileURLWithPath: output)
        let log = verbosity.log("twitter")
        runToExit(.appKit(showsWindow: true)) {
          try await TwitterCommands.exportSession(accountID: accountID, to: destination, log: log)
        }
      }
    }

    struct Enroll: ParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Create the passkey for X in a browser window (one-time setup)"
      )

      @OptionGroup var verbosity: Verbosity

      func run() {
        let log = verbosity.log("twitter")
        runToExit(.appKit(showsWindow: true)) {
          try await TwitterCommands.enroll(store: .default, log: log)
        }
      }
    }

    struct Logout: ParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Forget the saved X session; the next post signs in with the passkey again"
      )

      func run() throws {
        try TwitterCommands.logout()
        print("Saved X session forgotten")
      }
    }

    struct Probe: ParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Load X's login page without signing in and report what the page sees"
      )

      @OptionGroup var verbosity: Verbosity

      @Flag(help: "Show the browser window")
      var showBrowser = false

      func run() {
        let log = verbosity.log("twitter")
        runToExit(.appKit(showsWindow: showBrowser)) { [showBrowser] in
          let health = try await TwitterCommands.probe(
            store: .default, showsWindow: showBrowser, log: log)
          print(health)
        }
      }
    }
  }
#else
  import XPostChromium

  struct Twitter: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Check X (Twitter) access through the Chromium helper",
      discussion: """
        Posting to X drives X's web composer in headless Chromium through the helper under \
        helper/. Configure XPOST_TWITTER_HELPER, XPOST_TWITTER_USER, XPOST_TWITTER_ACCOUNT_ID \
        and XPOST_TWITTER_PASSWORD or XPOST_TWITTER_STATE_FILE.
        """,
      subcommands: [Check.self]
    )

    struct Check: ParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Sign in, verify the account and open the composer without posting"
      )

      @OptionGroup var verbosity: Verbosity

      func run() {
        let log = verbosity.log("twitter")
        let environment = ProcessInfo.processInfo.environment
        runToExit(.dispatch) {
          print(
            try await chromiumCheck(
              environment: environment, runner: processHelperRunner(), log: log))
        }
      }
    }
  }
#endif
