import ArgumentParser
import XPostCore

/// The `-V/--verbose` flag shared by every command that reaches a network.
struct Verbosity: ParsableArguments {
  @Flag(name: [.customShort("V"), .long], help: "Print debug messages to stderr")
  var verbose = false

  func log(_ category: String) -> RunLog {
    RunLog(category: category, isVerbose: verbose)
  }
}
