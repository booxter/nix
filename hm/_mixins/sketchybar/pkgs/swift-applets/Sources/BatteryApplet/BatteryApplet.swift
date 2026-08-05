import SketchyBarSupport

public struct BatteryState: Equatable {
  public let percentage: Int
  public let externalPower: Bool

  public init(percentage: Int, externalPower: Bool) {
    self.percentage = percentage
    self.externalPower = externalPower
  }
}

public protocol BatteryReading {
  func currentState() -> BatteryState?
}

public enum BatteryAppletError: Error, CustomStringConvertible {
  case missingItemName

  public var description: String {
    switch self {
    case .missingItemName:
      "NAME is required"
    }
  }
}

public final class BatteryApplet {
  private let reader: BatteryReading
  private let sketchyBar: SketchyBarRunning

  public init(reader: BatteryReading, sketchyBar: SketchyBarRunning) {
    self.reader = reader
    self.sketchyBar = sketchyBar
  }

  public func update(itemName: String?) throws {
    guard let itemName, !itemName.isEmpty else {
      throw BatteryAppletError.missingItemName
    }
    guard let state = reader.currentState() else {
      return
    }
    try sketchyBar.run([
      "--set", itemName,
      "icon=\(icon(for: state))",
      "label=\(state.percentage)%",
    ])
  }

  private func icon(for state: BatteryState) -> String {
    if state.externalPower {
      return "􀋦"
    }
    switch state.percentage {
    case 90...100: return "􀛨"
    case 60..<90: return "􀺸"
    case 30..<60: return "􀺶"
    case 10..<30: return "􀛩"
    default: return "􀛪"
    }
  }
}
