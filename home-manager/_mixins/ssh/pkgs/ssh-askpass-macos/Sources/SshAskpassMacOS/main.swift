import AskpassCore
import Darwin
import Foundation

let result = Askpass(prompter: AppKitPrompter()).run(
  arguments: Array(CommandLine.arguments.dropFirst()),
  environment: ProcessInfo.processInfo.environment
)

FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
exit(result.status)
