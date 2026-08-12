import BatteryApplet
import Foundation
import SketchyBarSupport

private enum CheckFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
    case .failed(let message): message
    }
  }
}

private struct FixedBatteryReader: BatteryReading {
  let state: BatteryState?

  func currentState() -> BatteryState? {
    state
  }
}

private final class RecordingSketchyBar: SketchyBarRunning {
  var calls: [[String]] = []

  func run(_ arguments: [String]) {
    calls.append(arguments)
  }
}

private func expectEqual<T: Equatable>(
  _ actual: T,
  _ expected: T,
  _ context: String
) throws {
  guard actual == expected else {
    throw CheckFailure.failed("\(context): expected \(expected), got \(actual)")
  }
}

do {
  for (percentage, icon) in [
    (100, "􀛨"),
    (89, "􀺸"),
    (59, "􀺶"),
    (29, "􀛩"),
    (9, "􀛪"),
  ] {
    let bar = RecordingSketchyBar()
    let applet = BatteryApplet(
      reader: FixedBatteryReader(
        state: BatteryState(percentage: percentage, externalPower: false)
      ),
      sketchyBar: bar
    )
    try applet.update(itemName: "battery")
    try expectEqual(
      bar.calls,
      [["--set", "battery", "icon=\(icon)", "label=\(percentage)%"]],
      "battery at \(percentage)%"
    )
  }

  let externalPowerBar = RecordingSketchyBar()
  try BatteryApplet(
    reader: FixedBatteryReader(
      state: BatteryState(percentage: 100, externalPower: true)
    ),
    sketchyBar: externalPowerBar
  ).update(itemName: "battery")
  try expectEqual(
    externalPowerBar.calls[0][2],
    "icon=􀋦",
    "external power icon"
  )

  let noBatteryBar = RecordingSketchyBar()
  try BatteryApplet(
    reader: FixedBatteryReader(state: nil),
    sketchyBar: noBatteryBar
  ).update(itemName: "battery")
  try expectEqual(noBatteryBar.calls, [], "missing battery")

  do {
    try BatteryApplet(
      reader: FixedBatteryReader(state: nil),
      sketchyBar: RecordingSketchyBar()
    ).update(itemName: nil)
    throw CheckFailure.failed("missing NAME was accepted")
  } catch BatteryAppletError.missingItemName {}

  print("Battery applet checks passed")
} catch {
  FileHandle.standardError.write(Data("Battery applet check failed: \(error)\n".utf8))
  exit(EXIT_FAILURE)
}
