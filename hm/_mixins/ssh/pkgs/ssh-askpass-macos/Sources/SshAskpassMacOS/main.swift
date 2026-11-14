import AskpassCore
import Darwin
import Foundation

let environment = ProcessInfo.processInfo.environment
let namedKeysJSON = environment["SSH_ASKPASS_NAMED_KEYS"] ?? "[]"
let namedPublicKeys = try JSONDecoder().decode(
  [NamedPublicKey].self, from: Data(namedKeysJSON.utf8)
)
let indicator = environment["SSH_ASKPASS_INDICATOR"].map { executable in
  RequestIndicator(executable: executable)
}

let result = Askpass(
  prompter: AppKitPrompter(), namedPublicKeys: namedPublicKeys, indicator: indicator
).run(
  arguments: Array(CommandLine.arguments.dropFirst()),
  environment: environment
)

FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
exit(result.status)
