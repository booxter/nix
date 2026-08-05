// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "ssh-askpass-macos",
  platforms: [.macOS(.v14)],
  products: [
    .executable(
      name: "ssh-askpass-macos",
      targets: ["SshAskpassMacOS"]
    )
  ],
  targets: [
    .target(name: "AskpassCore"),
    .executableTarget(
      name: "SshAskpassMacOS",
      dependencies: ["AskpassCore"]
    ),
    // nixpkgs patches SwiftPM on Darwin to remove its dependency on Apple's
    // non-free xctest command-line runner, so `swift test` cannot run normal
    // `.testTarget`s in a Nix build. This executable is a behavioral test
    // runner invoked by checkPhase. Convert it back to a `.testTarget` once
    // nixpkgs provides a usable Darwin Swift test runner.
    .executableTarget(
      name: "AskpassCoreChecks",
      dependencies: ["AskpassCore"],
      path: "Tests/AskpassCoreChecks"
    ),
  ]
)
