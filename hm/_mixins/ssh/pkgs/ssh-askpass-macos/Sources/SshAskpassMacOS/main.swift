import AskpassCore
import Darwin
import Foundation

let environment = ProcessInfo.processInfo.environment
let namedKeysJSON = environment["SSH_ASKPASS_NAMED_KEYS"] ?? "{}"
let namedPublicKeys = try JSONDecoder().decode(
  [String: String].self, from: Data(namedKeysJSON.utf8)
)

let result = Askpass(prompter: AppKitPrompter(), namedPublicKeys: namedPublicKeys).run(
  arguments: Array(CommandLine.arguments.dropFirst()),
  environment: environment
)

FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
exit(result.status)
