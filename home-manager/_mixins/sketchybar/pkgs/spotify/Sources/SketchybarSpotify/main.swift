import Foundation
import SpotifyApplet

do {
  let environment = try AppletEnvironment(
    environment: ProcessInfo.processInfo.environment
  )
  let applet = SpotifyApplet(
    spotify: AppleScriptSpotifyController(),
    sketchyBar: ProcessSketchyBarRunner(
      executable: environment.sketchyBarExecutable
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
