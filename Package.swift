// swift-tools-version: 6.2
import PackageDescription

var xpostDependencies: [Target.Dependency] = [
  "XPostCore",
  "XPostChromium",
  .product(name: "ArgumentParser", package: "swift-argument-parser"),
]

var targets: [Target] = [
  .target(name: "XPostCore"),
  // Posts to X through the Node/Playwright helper under helper/. Built everywhere so its
  // tests run on macOS too; the executable uses it only where WebKit is not available.
  .target(name: "XPostChromium", dependencies: ["XPostCore"]),
  .testTarget(name: "XPostCoreTests", dependencies: ["XPostCore"]),
  .testTarget(name: "XPostChromiumTests", dependencies: ["XPostChromium"]),
  .testTarget(name: "xpostTests", dependencies: ["xpost"]),
]

// The X backend built on WebKit, the Secure Enclave and the keychain exists only on macOS;
// its sources and tests are not part of the package elsewhere.
#if os(macOS)
  targets += [
    .target(name: "XPostTwitter", dependencies: ["XPostCore"]),
    .testTarget(name: "XPostTwitterTests", dependencies: ["XPostTwitter"]),
  ]
  xpostDependencies.append("XPostTwitter")
#endif

targets.append(.executableTarget(name: "xpost", dependencies: xpostDependencies))

let package = Package(
  name: "xpost",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
  ],
  targets: targets
)
