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
    // nixpkgs patches SwiftPM on Darwin to remove its dependency on Apple's
    // non-free xctest command-line runner, so `swift test` cannot run normal
    // `.testTarget`s in a Nix build. These executable targets are behavioral
    // test runners invoked by checkPhase. Convert them back to `.testTarget`s
    // once nixpkgs provides a usable Darwin Swift test runner.
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
