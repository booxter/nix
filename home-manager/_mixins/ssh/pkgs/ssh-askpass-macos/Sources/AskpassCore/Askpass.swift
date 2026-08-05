public let defaultPrompt = "OpenSSH authentication"

public protocol Prompting {
  func confirm(prompt: String) -> Bool
  func readSecret(prompt: String) -> String?
}

public struct AskpassResult: Equatable {
  public let standardOutput: String
  public let status: Int32

  public init(standardOutput: String, status: Int32) {
    self.standardOutput = standardOutput
    self.status = status
  }
}

public struct Askpass {
  private let prompter: Prompting

  public init(prompter: Prompting) {
    self.prompter = prompter
  }

  public func run(
    arguments: [String],
    environment: [String: String]
  ) -> AskpassResult {
    let prompt = arguments.first.flatMap { $0.isEmpty ? nil : $0 } ?? defaultPrompt

    if environment["SSH_ASKPASS_PROMPT"] == "confirm" {
      guard prompter.confirm(prompt: prompt) else {
        return AskpassResult(standardOutput: "", status: 1)
      }
      return AskpassResult(standardOutput: "yes\n", status: 0)
    }

    guard let secret = prompter.readSecret(prompt: prompt) else {
      return AskpassResult(standardOutput: "", status: 1)
    }
    return AskpassResult(standardOutput: "\(secret)\n", status: 0)
  }
}
