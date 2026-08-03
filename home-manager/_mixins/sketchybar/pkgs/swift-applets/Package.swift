// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "sketchybar-swift-applets",
  platforms: [.macOS(.v14)],
  products: [
    .executable(
      name: "sketchybar-battery",
      targets: ["SketchybarBattery"]
    ),
    .executable(
      name: "sketchybar-spotify",
      targets: ["SketchybarSpotify"]
    ),
  ],
  targets: [
    .target(name: "SketchyBarSupport"),
    .target(
      name: "BatteryApplet",
      dependencies: ["SketchyBarSupport"]
    ),
    .executableTarget(
      name: "SketchybarBattery",
      dependencies: ["BatteryApplet", "SketchyBarSupport"]
    ),
    .target(
      name: "SpotifyApplet",
      dependencies: ["SketchyBarSupport"]
    ),
    .executableTarget(
      name: "SketchybarSpotify",
      dependencies: ["SketchyBarSupport", "SpotifyApplet"]
    ),
    // nixpkgs disables SwiftPM's Darwin XCTest runner because Apple's xctest
    // command-line runner is not open source. Keep checks executable until
    // nixpkgs has a native test runner for Swift packages on Darwin.
    .executableTarget(
      name: "BatteryAppletChecks",
      dependencies: ["BatteryApplet", "SketchyBarSupport"],
      path: "Tests/BatteryAppletChecks"
    ),
    .executableTarget(
      name: "SpotifyAppletChecks",
      dependencies: ["SketchyBarSupport", "SpotifyApplet"],
      path: "Tests/SpotifyAppletChecks"
    ),
  ]
)
