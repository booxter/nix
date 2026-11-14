// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "home-split-dns",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "home-split-dns", targets: ["HomeSplitDNSCommand"])],
  targets: [
    .target(name: "HomeSplitDNS"),
    .executableTarget(name: "HomeSplitDNSCommand", dependencies: ["HomeSplitDNS"]),
    // Use executable checks, as in the other Darwin helpers: nixpkgs SwiftPM
    // does not provide a usable XCTest runner.
    .executableTarget(
      name: "HomeSplitDNSChecks",
      dependencies: ["HomeSplitDNS"],
      path: "Tests/HomeSplitDNSChecks"
    ),
  ]
)
