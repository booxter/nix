public let defaultPrompt = "OpenSSH authentication"

public protocol Prompting {
  func notify(prompt: String)
  func confirm(prompt: String) -> Bool
  func readSecret(prompt: String) -> String?
}

public protocol PromptIndicating {
  func show(name: String)
  func hide()
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
  private let aliases: KeyAliases
  private let indicator: PromptIndicating?

  public init(
    prompter: Prompting,
    namedPublicKeys: [NamedPublicKey] = [],
    indicator: PromptIndicating? = nil
  ) {
    self.prompter = prompter
    aliases = KeyAliases(publicKeys: namedPublicKeys)
    self.indicator = indicator
  }

  public func run(
    arguments: [String],
    environment: [String: String]
  ) -> AskpassResult {
    let originalPrompt = arguments.first.flatMap { $0.isEmpty ? nil : $0 } ?? defaultPrompt
    let key = aliases.key(for: originalPrompt)
    let prompt = key.map { "\($0.label)\n\n\(originalPrompt)" } ?? originalPrompt

    if let key {
      indicator?.show(name: key.name)
    }
    defer {
      if key != nil {
        indicator?.hide()
      }
    }

    // OpenSSH uses "none" for touch notifications and ignores their output.
    if environment["SSH_ASKPASS_PROMPT"] == "none" {
      prompter.notify(prompt: prompt)
      return AskpassResult(standardOutput: "", status: 0)
    }

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
