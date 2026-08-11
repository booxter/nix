// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "darwin-launchd-exporter",
  platforms: [.macOS(.v14)],
  products: [
    .executable(
      name: "observability-launchd-export",
      targets: ["ObservabilityLaunchdExport"]
    ),
  ],
  targets: [
    .target(name: "LaunchdExporter"),
    .executableTarget(
      name: "ObservabilityLaunchdExport",
      dependencies: ["LaunchdExporter"]
    ),
    // nixpkgs patches SwiftPM on Darwin to remove its dependency on Apple's
    // non-free xctest command-line runner. Keep behavioral checks as a normal
    // executable until nixpkgs provides a usable XCTest runner.
    .executableTarget(
      name: "LaunchdExporterChecks",
      dependencies: ["LaunchdExporter"],
      path: "Tests/LaunchdExporterChecks"
    ),
  ]
)
