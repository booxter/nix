// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "darwin-thermal-exporter",
  platforms: [.macOS(.v14)],
  products: [
    .executable(
      name: "observability-thermal-export",
      targets: ["ObservabilityThermalExport"]
    ),
  ],
  targets: [
    .target(name: "ThermalExporter"),
    .executableTarget(
      name: "ObservabilityThermalExport",
      dependencies: ["ThermalExporter"]
    ),
    // nixpkgs patches SwiftPM on Darwin to remove its dependency on Apple's
    // non-free xctest command-line runner. Keep behavioral checks as a normal
    // executable until nixpkgs provides a usable XCTest runner.
    .executableTarget(
      name: "ThermalExporterChecks",
      dependencies: ["ThermalExporter"],
      path: "Tests/ThermalExporterChecks"
    ),
  ]
)
