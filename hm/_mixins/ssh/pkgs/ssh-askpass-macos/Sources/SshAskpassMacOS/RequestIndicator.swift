import AskpassCore
import Foundation

final class RequestIndicator: PromptIndicating {
  private let executable: String
  private var process: Process?
  private var input: Pipe?

  init(executable: String) {
    self.executable = executable
  }

  func show(name: String) {
    hide()

    let request = Process()
    let pipe = Pipe()
    request.executableURL = URL(fileURLWithPath: executable)
    request.arguments = ["--label", name]
    request.standardInput = pipe
    request.standardOutput = FileHandle.nullDevice
    request.standardError = FileHandle.nullDevice

    do {
      try request.run()
      process = request
      input = pipe
    } catch {
      // Reporting must not prevent authentication or contaminate PIN output.
      try? pipe.fileHandleForWriting.close()
    }
    try? pipe.fileHandleForReading.close()
  }

  func hide() {
    // EOF also reaches the helper if OpenSSH terminates this process during a
    // touch notification. The helper owns display cleanup, including that case.
    try? input?.fileHandleForWriting.close()
    process?.waitUntilExit()
    input = nil
    process = nil
  }

  deinit {
    hide()
  }
}
