// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "sketchybar-spotify",
  platforms: [.macOS(.v14)],
  products: [
    .executable(
      name: "sketchybar-spotify",
      targets: ["SketchybarSpotify"]
    )
  ],
  targets: [
    .target(name: "SpotifyApplet"),
    .executableTarget(
      name: "SketchybarSpotify",
      dependencies: ["SpotifyApplet"]
    ),
    // nixpkgs disables SwiftPM's Darwin XCTest runner because Apple's xctest
    // command-line runner is not open source. Keep checks executable until
    // nixpkgs has a native test runner for Swift packages on Darwin.
    .executableTarget(
      name: "SpotifyAppletChecks",
      dependencies: ["SpotifyApplet"],
      path: "Tests/SpotifyAppletChecks"
    ),
  ]
)
