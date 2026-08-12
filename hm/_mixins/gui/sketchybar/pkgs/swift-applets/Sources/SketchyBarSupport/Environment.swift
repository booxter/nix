import Foundation

public struct SketchyBarEnvironment {
  public let executable: URL
  public let sender: String?
  public let itemName: String?
  public let info: String?

  public init(environment: [String: String]) throws {
    guard let executable = environment["SKETCHYBAR_BIN"], !executable.isEmpty else {
      throw ConfigurationError.missingSketchyBarExecutable
    }
    self.executable = URL(fileURLWithPath: executable)
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
