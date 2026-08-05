import Foundation
import SketchyBarSupport
import SpotifyApplet

private enum CheckFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
    case .failed(let message): message
    }
  }
}

private enum FakeError: Error {
  case failed
}

private final class RecordingSpotify: SpotifyControlling {
  var actions: [TransportAction] = []
  var settings: [SpotifySetting: Bool] = [:]
  var requestedSettings: [SpotifySetting] = []
  var changedSettings: [(SpotifySetting, Bool)] = []
  var error: Error?

  func perform(_ action: TransportAction) throws {
    if let error { throw error }
    actions.append(action)
  }

  func isEnabled(_ setting: SpotifySetting) throws -> Bool {
    requestedSettings.append(setting)
    if let error { throw error }
    return settings[setting] ?? false
  }

  func set(_ setting: SpotifySetting, enabled: Bool) throws {
    if let error { throw error }
    settings[setting] = enabled
    changedSettings.append((setting, enabled))
  }
}

private final class RecordingSketchyBar: SketchyBarRunning {
  var calls: [[String]] = []

  func run(_ arguments: [String]) {
    calls.append(arguments)
  }
}

private struct Fixture {
  let spotify = RecordingSpotify()
  let sketchyBar = RecordingSketchyBar()

  var applet: SpotifyApplet {
    SpotifyApplet(spotify: spotify, sketchyBar: sketchyBar)
  }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else {
    throw CheckFailure.failed(message)
  }
}

private func expectEqual<T: Equatable>(
  _ actual: T,
  _ expected: T,
  _ context: String
) throws {
  try expect(actual == expected, "\(context): expected \(expected), got \(actual)")
}

do {
  let playing = Fixture()
  playing.spotify.settings = [.shuffling: true, .repeating: false]
  try playing.applet.handle(
    sender: "spotify_change",
    itemName: nil,
    info: """
      {
        "Player State": "Playing",
        "Name": "Motion Picture Soundtrack",
        "Artist": "Radiohead",
        "Album": "Kid A"
      }
      """
  )
  try expectEqual(
    playing.sketchyBar.calls,
    [
      [
        "-m",
        "--set", "spotify.name",
        "label=􀑪 Motion Picture Soundtrack 􀉮 Radiohead",
        "drawing=on",
        "--set", "spotify.play", "icon=􀊆",
        "--set", "spotify.shuffle", "icon.highlight=on",
        "--set", "spotify.repeat", "icon.highlight=off",
      ]
    ],
    "playing state"
  )

  let albumFallback = Fixture()
  try albumFallback.applet.handle(
    sender: nil,
    itemName: nil,
    info: """
      {"Player State":"Playing","Name":"Track","Album":"Album"}
      """
  )
  try expect(
    albumFallback.sketchyBar.calls[0].contains("label=􀑪 Track 􀉮 Album"),
    "album did not replace a missing artist"
  )

  let stopped = Fixture()
  for info in ["{\"Player State\":\"Paused\"}", "not JSON", nil] {
    try stopped.applet.handle(sender: nil, itemName: nil, info: info)
  }
  try expectEqual(stopped.sketchyBar.calls.count, 3, "stopped updates")
  for call in stopped.sketchyBar.calls {
    try expectEqual(
      call,
      [
        "-m",
        "--set", "spotify.name", "drawing=off",
        "--set", "spotify.name", "popup.drawing=off",
        "--set", "spotify.play", "icon=􀊄",
      ],
      "stopped state"
    )
  }

  let transport = Fixture()
  for (name, action) in [
    ("spotify.next", TransportAction.next),
    ("spotify.back", .previous),
    ("spotify.play", .playPause),
  ] {
    try transport.applet.handle(
      sender: "mouse.clicked",
      itemName: name,
      info: nil
    )
    try expectEqual(transport.spotify.actions.last, action, name)
  }

  let toggle = Fixture()
  toggle.spotify.settings[.shuffling] = false
  try toggle.applet.handle(
    sender: "mouse.clicked",
    itemName: "spotify.shuffle",
    info: nil
  )
  try expectEqual(toggle.spotify.changedSettings.count, 1, "shuffle changes")
  try expectEqual(
    toggle.spotify.changedSettings[0].0,
    .shuffling,
    "shuffle setting"
  )
  try expect(toggle.spotify.changedSettings[0].1, "shuffle was not enabled")
  try expectEqual(
    toggle.sketchyBar.calls,
    [["-m", "--set", "spotify.shuffle", "icon.highlight=on"]],
    "shuffle highlight"
  )

  let ignored = Fixture()
  try ignored.applet.handle(sender: "forced", itemName: nil, info: nil)
  try ignored.applet.handle(
    sender: "mouse.clicked",
    itemName: "spotify.unknown",
    info: nil
  )
  try expect(ignored.spotify.actions.isEmpty, "ignored event changed Spotify")
  try expect(ignored.sketchyBar.calls.isEmpty, "ignored event changed SketchyBar")

  let unavailableSettings = Fixture()
  unavailableSettings.spotify.error = FakeError.failed
  try unavailableSettings.applet.handle(
    sender: nil,
    itemName: nil,
    info: "{\"Player State\":\"Playing\",\"Name\":\"Track\"}"
  )
  try expect(
    unavailableSettings.sketchyBar.calls[0].contains("icon.highlight=off"),
    "failed setting query did not fall back to disabled"
  )

  do {
    _ = try SketchyBarEnvironment(environment: [:])
    throw CheckFailure.failed("missing SKETCHYBAR_BIN was accepted")
  } catch ConfigurationError.missingSketchyBarExecutable {}
  let environment = try SketchyBarEnvironment(environment: [
    "SKETCHYBAR_BIN": "/nix/store/example/bin/sketchybar",
    "SENDER": "forced",
  ])
  try expectEqual(
    environment.executable.path,
    "/nix/store/example/bin/sketchybar",
    "SketchyBar executable"
  )
  try expectEqual(environment.sender, "forced", "sender")

  print("Spotify applet checks passed")
} catch {
  FileHandle.standardError.write(Data("Spotify applet check failed: \(error)\n".utf8))
  exit(EXIT_FAILURE)
}
