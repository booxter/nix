import AskpassCore
import Darwin
import Foundation

let environment = ProcessInfo.processInfo.environment
let namedKeysJSON = environment["SSH_ASKPASS_NAMED_KEYS"] ?? "[]"
let namedPublicKeys = try JSONDecoder().decode(
  [NamedPublicKey].self, from: Data(namedKeysJSON.utf8)
)
let indicator = try environment["SSH_ASKPASS_INDICATOR"].map { json in
  SketchyBarIndicator(
    configuration: try JSONDecoder().decode(IndicatorConfiguration.self, from: Data(json.utf8))
  )
}

let result = Askpass(
  prompter: AppKitPrompter(), namedPublicKeys: namedPublicKeys, indicator: indicator
).run(
  arguments: Array(CommandLine.arguments.dropFirst()),
  environment: environment
)

FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
exit(result.status)
