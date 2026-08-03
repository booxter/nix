import Foundation

public struct AppletEnvironment {
  public let sketchyBarExecutable: URL
  public let sender: String?
  public let itemName: String?
  public let info: String?

  public init(environment: [String: String]) throws {
    guard let executable = environment["SKETCHYBAR_BIN"], !executable.isEmpty else {
      throw ConfigurationError.missingSketchyBarExecutable
    }
    sketchyBarExecutable = URL(fileURLWithPath: executable)
    sender = environment["SENDER"]
    itemName = environment["NAME"]
    info = environment["INFO"]
  }
}

public enum ConfigurationError: Error, CustomStringConvertible {
  case missingSketchyBarExecutable

  public var description: String {
    switch self {
    case .missingSketchyBarExecutable:
      "SKETCHYBAR_BIN is required"
    }
  }
}

private struct PlaybackInfo: Decodable {
  let playerState: String?
  let name: String?
  let artist: String?
  let album: String?

  enum CodingKeys: String, CodingKey {
    case playerState = "Player State"
    case name = "Name"
    case artist = "Artist"
    case album = "Album"
  }
}

public final class SpotifyApplet {
  private let spotify: SpotifyControlling
  private let sketchyBar: SketchyBarRunning

  public init(
    spotify: SpotifyControlling,
    sketchyBar: SketchyBarRunning
  ) {
    self.spotify = spotify
    self.sketchyBar = sketchyBar
  }

  public func handle(
    sender: String?,
    itemName: String?,
    info: String?
  ) throws {
    switch sender {
    case "mouse.clicked":
      try handleClick(itemName: itemName)
    case "forced":
      return
    default:
      try update(info: info)
    }
  }

  private func handleClick(itemName: String?) throws {
    switch itemName {
    case "spotify.next":
      try spotify.perform(.next)
    case "spotify.back":
      try spotify.perform(.previous)
    case "spotify.play":
      try spotify.perform(.playPause)
    case "spotify.shuffle":
      try toggle(.shuffling, item: "spotify.shuffle")
    case "spotify.repeat":
      try toggle(.repeating, item: "spotify.repeat")
    default:
      return
    }
  }

  private func toggle(_ setting: SpotifySetting, item: String) throws {
    let enabled = !(try spotify.isEnabled(setting))
    try spotify.set(setting, enabled: enabled)
    try sketchyBar.run([
      "-m", "--set", item,
      "icon.highlight=\(enabled ? "on" : "off")",
    ])
  }

  private func update(info: String?) throws {
    guard
      let info,
      let data = info.data(using: .utf8),
      let playback = try? JSONDecoder().decode(PlaybackInfo.self, from: data),
      playback.playerState == "Playing"
    else {
      try showStopped()
      return
    }

    let track = playback.name ?? ""
    let performer = nonempty(playback.artist) ?? playback.album ?? ""
    let shuffling = (try? spotify.isEnabled(.shuffling)) ?? false
    let repeating = (try? spotify.isEnabled(.repeating)) ?? false

    try sketchyBar.run([
      "-m",
      "--set", "spotify.name",
      "label=􀑪 \(track) 􀉮 \(performer)",
      "drawing=on",
      "--set", "spotify.play", "icon=􀊆",
      "--set", "spotify.shuffle",
      "icon.highlight=\(shuffling ? "on" : "off")",
      "--set", "spotify.repeat",
      "icon.highlight=\(repeating ? "on" : "off")",
    ])
  }

  private func showStopped() throws {
    try sketchyBar.run([
      "-m",
      "--set", "spotify.name", "drawing=off",
      "--set", "spotify.name", "popup.drawing=off",
      "--set", "spotify.play", "icon=􀊄",
    ])
  }

  private func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
      return nil
    }
    return value
  }
}
