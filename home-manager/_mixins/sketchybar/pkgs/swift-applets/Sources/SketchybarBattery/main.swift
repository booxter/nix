import BatteryApplet
import Foundation
import SketchyBarSupport

do {
  let environment = try SketchyBarEnvironment(
    environment: ProcessInfo.processInfo.environment
  )
  let applet = BatteryApplet(
    reader: IOKitBatteryReader(),
    sketchyBar: ProcessSketchyBarRunner(executable: environment.executable)
  )
  try applet.update(itemName: environment.itemName)
} catch {
  FileHandle.standardError.write(
    Data("sketchybar-battery: \(error)\n".utf8)
  )
  exit(EXIT_FAILURE)
}
