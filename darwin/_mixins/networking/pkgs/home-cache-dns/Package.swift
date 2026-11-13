// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "home-cache-dns",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "home-cache-dns", targets: ["HomeCacheDNSCommand"])],
  targets: [
    .target(name: "HomeCacheDNS"),
    .executableTarget(name: "HomeCacheDNSCommand", dependencies: ["HomeCacheDNS"]),
    // Use executable checks, as in the other Darwin helpers: nixpkgs SwiftPM
    // does not provide a usable XCTest runner.
    .executableTarget(
      name: "HomeCacheDNSChecks",
      dependencies: ["HomeCacheDNS"],
      path: "Tests/HomeCacheDNSChecks"
    ),
  ]
)
