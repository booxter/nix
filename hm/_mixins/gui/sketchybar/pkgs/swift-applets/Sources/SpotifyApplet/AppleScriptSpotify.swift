import Foundation

public enum TransportAction: Equatable {
  case next
  case previous
  case playPause
}

public enum SpotifySetting: Equatable {
  case repeating
  case shuffling
}

public protocol SpotifyControlling {
  func perform(_ action: TransportAction) throws
  func isEnabled(_ setting: SpotifySetting) throws -> Bool
  func set(_ setting: SpotifySetting, enabled: Bool) throws
}

public struct AppleScriptError: Error, CustomStringConvertible {
  public let details: String

  public var description: String {
    "AppleScript failed: \(details)"
  }
}

public final class AppleScriptSpotifyController: SpotifyControlling {
  public init() {}

  public func perform(_ action: TransportAction) throws {
    let command =
      switch action {
      case .next: "play next track"
      case .previous: "play previous track"
      case .playPause: "playpause"
      }
    _ = try execute("tell application \"Spotify\" to \(command)")
  }

  public func isEnabled(_ setting: SpotifySetting) throws -> Bool {
    try execute(
      "tell application \"Spotify\" to get \(property(for: setting))"
    ).booleanValue
  }

  public func set(_ setting: SpotifySetting, enabled: Bool) throws {
    _ = try execute(
      "tell application \"Spotify\" to set \(property(for: setting)) "
        + "to \(enabled)"
    )
  }

  private func property(for setting: SpotifySetting) -> String {
    switch setting {
    case .repeating: "repeating"
    case .shuffling: "shuffling"
    }
  }

  private func execute(_ source: String) throws -> NSAppleEventDescriptor {
    guard let script = NSAppleScript(source: source) else {
      throw AppleScriptError(details: "could not compile script")
    }

    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error {
      let details =
        error
        .map { "\($0.key)=\($0.value)" }
        .sorted()
        .joined(separator: ", ")
      throw AppleScriptError(details: details)
    }
    return result
  }
}
