import Foundation
import Testing

@testable import XPostCore

@Suite struct FailureScreenshotTests {
  @Test func createsAPrivateDirectoryForEachScreenshot() throws {
    let manager = FileManager.default
    var directories: [URL] = []
    defer {
      for directory in directories { try? manager.removeItem(at: directory) }
    }

    for _ in 0..<2 {
      let screenshot = URL(fileURLWithPath: try failureScreenshotPath())
      let directory = screenshot.deletingLastPathComponent()
      try #require(directory.lastPathComponent.hasPrefix("xpost-"))
      try #require(
        directory.deletingLastPathComponent().standardizedFileURL
          == manager.temporaryDirectory.standardizedFileURL)
      directories.append(directory)

      let attributes = try manager.attributesOfItem(atPath: directory.path)
      #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
      #expect(attributes[.posixPermissions] as? Int == 0o700)
      #expect(!manager.fileExists(atPath: screenshot.path))
    }

    #expect(directories[0] != directories[1])
  }
}
