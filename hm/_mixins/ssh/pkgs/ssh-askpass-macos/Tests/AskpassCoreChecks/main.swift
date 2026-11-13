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
  var notifications: [String] = []
  var confirmationPrompts: [String] = []
  var secretPrompts: [String] = []

  func notify(prompt: String) {
    notifications.append(prompt)
  }

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
  let mainName = "work.main (serial 32147445)"
  let laptopName = "work.laptop (serial 32147427)"
  let namedKeys = [
    mainName:
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIJUL5v17Cixk6bg/ch0QlcrEOfIUP81Ys/Qdot6ILfccAAAABHNzaDo= ignored-comment",
    laptopName:
      "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIKbJ9tWOVxULqS7IRxPECfcgan5LwcmaprSC9HCtILnoAAAABHNzaDo= another-comment",
  ]
  let fingerprints = [
    mainName: "SHA256:5vJuvsq/AWg5hNkRCH92Jeb8y1LGeDdO39tLnWG0EDo",
    laptopName: "SHA256:czsVjmoKx1CMxN5EAmVtwjeEApnG6J1CFiG8Cd4y7L4",
  ]
  for (name, fingerprint) in fingerprints {
    let prompter = RecordingPrompter()
    let askpass = Askpass(prompter: prompter, namedPublicKeys: namedKeys)
    let touch = "Confirm user presence for key ED25519-SK \(fingerprint)"
    let pin = "Enter PIN and confirm user presence for ED25519-SK key \(fingerprint): "
    _ = askpass.run(arguments: [touch], environment: ["SSH_ASKPASS_PROMPT": "none"])
    _ = askpass.run(arguments: [pin], environment: [:])
    try expectEqual(prompter.notifications, ["\(name)\n\n\(touch)"], "named touch prompt")
    try expectEqual(prompter.secretPrompts, ["\(name)\n\n\(pin)"], "named PIN prompt")
  }

  let unknown = RecordingPrompter()
  let unknownPrompts = [
    "Password:",
    "Enter PIN for SHA256:unknown:",
    "Enter PIN for \(fingerprints[mainName]!)extra:",
  ]
  for prompt in unknownPrompts {
    _ = Askpass(prompter: unknown, namedPublicKeys: namedKeys).run(
      arguments: [prompt], environment: [:]
    )
  }
  try expectEqual(unknown.secretPrompts, unknownPrompts, "unknown prompts remain unchanged")

  let notification = RecordingPrompter()
  let notificationResult = Askpass(prompter: notification).run(
    arguments: ["Confirm user presence for key ED25519-SK"],
    environment: ["SSH_ASKPASS_PROMPT": "none"]
  )
  try expectEqual(
    notificationResult,
    AskpassResult(standardOutput: "", status: 0),
    "notification has no response"
  )
  try expectEqual(
    notification.notifications,
    ["Confirm user presence for key ED25519-SK"],
    "touch notification"
  )
  try expectEqual(notification.secretPrompts, [], "notification must not request a PIN")
  try expectEqual(notification.confirmationPrompts, [], "notification needs no approval")

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
