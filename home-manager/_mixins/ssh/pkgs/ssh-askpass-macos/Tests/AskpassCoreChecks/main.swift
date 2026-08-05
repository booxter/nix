import AskpassCore
import Darwin
import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
    case .failed(let message): message
    }
  }
}

private final class RecordingPrompter: Prompting {
  var confirmation = false
  var secret: String?
  var confirmationPrompts: [String] = []
  var secretPrompts: [String] = []

  func confirm(prompt: String) -> Bool {
    confirmationPrompts.append(prompt)
    return confirmation
  }

  func readSecret(prompt: String) -> String? {
    secretPrompts.append(prompt)
    return secret
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
  let password = RecordingPrompter()
  password.secret = "correct horse battery staple"
  let passwordResult = Askpass(prompter: password).run(
    arguments: ["Password:", "ignored"],
    environment: [:]
  )
  try expectEqual(
    passwordResult,
    AskpassResult(standardOutput: "correct horse battery staple\n", status: 0),
    "password response"
  )
  try expectEqual(password.secretPrompts, ["Password:"], "password prompt")
  try expectEqual(password.confirmationPrompts, [], "password confirmation calls")

  let defaulted = RecordingPrompter()
  defaulted.secret = ""
  for arguments in [[], [""]] {
    let result = Askpass(prompter: defaulted).run(arguments: arguments, environment: [:])
    try expectEqual(
      result,
      AskpassResult(standardOutput: "\n", status: 0),
      "empty password"
    )
  }
  try expectEqual(
    defaulted.secretPrompts,
    [defaultPrompt, defaultPrompt],
    "default prompt"
  )

  let accepted = RecordingPrompter()
  accepted.confirmation = true
  let acceptedResult = Askpass(prompter: accepted).run(
    arguments: ["Allow key use?"],
    environment: ["SSH_ASKPASS_PROMPT": "confirm"]
  )
  try expectEqual(
    acceptedResult,
    AskpassResult(standardOutput: "yes\n", status: 0),
    "accepted confirmation"
  )
  try expectEqual(accepted.confirmationPrompts, ["Allow key use?"], "confirm prompt")
  try expectEqual(accepted.secretPrompts, [], "confirm secret calls")

  let rejected = RecordingPrompter()
  let rejectedResult = Askpass(prompter: rejected).run(
    arguments: [],
    environment: ["SSH_ASKPASS_PROMPT": "confirm"]
  )
  try expectEqual(
    rejectedResult,
    AskpassResult(standardOutput: "", status: 1),
    "rejected confirmation"
  )

  let cancelled = RecordingPrompter()
  let cancelledResult = Askpass(prompter: cancelled).run(
    arguments: ["Password:"],
    environment: [:]
  )
  try expectEqual(
    cancelledResult,
    AskpassResult(standardOutput: "", status: 1),
    "cancelled password"
  )

  print("macOS askpass checks passed")
} catch {
  FileHandle.standardError.write(Data("macOS askpass check failed: \(error)\n".utf8))
  exit(EXIT_FAILURE)
}
