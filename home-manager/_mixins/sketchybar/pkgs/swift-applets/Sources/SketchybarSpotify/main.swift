import Foundation
import SketchyBarSupport
import SpotifyApplet

do {
  let environment = try SketchyBarEnvironment(
    environment: ProcessInfo.processInfo.environment
  )
  let applet = SpotifyApplet(
    spotify: AppleScriptSpotifyController(),
    sketchyBar: ProcessSketchyBarRunner(
      executable: environment.executable
    )
  )
  try applet.handle(
    sender: environment.sender,
    itemName: environment.itemName,
    info: environment.info
  )
} catch {
  FileHandle.standardError.write(
    Data("sketchybar-spotify: \(error)\n".utf8)
  )
  exit(EXIT_FAILURE)
}
