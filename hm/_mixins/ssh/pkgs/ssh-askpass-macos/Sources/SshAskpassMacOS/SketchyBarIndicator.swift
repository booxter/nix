import AskpassCore
import Darwin
import Foundation

struct IndicatorConfiguration: Decodable {
  let executable: String
  let background: String
  let foreground: String
}

final class SketchyBarIndicator: PromptIndicating {
  private let configuration: IndicatorConfiguration
  private let item = "ssh_key_\(getpid())"
  private let lock = NSLock()
  private var visible = false
  private var signalSources: [DispatchSourceSignal] = []

  init(configuration: IndicatorConfiguration) {
    self.configuration = configuration

    // OpenSSH ends touch notifications with SIGTERM, bypassing normal cleanup.
    // Handle it off the main queue, which may be running an AppKit modal dialog.
    for number in [SIGTERM, SIGINT, SIGHUP] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { [weak self] in
        self?.hide()
        _exit(128 + number)
      }
      source.resume()
      signalSources.append(source)
    }
  }

  func show(name: String) {
    lock.lock()
    defer { lock.unlock() }

    // A separate item per prompt prevents concurrent requests hiding each other.
    visible = true
    run([
      "--add", "item", item, "right",
      "--set", item,
      "icon=🔑", "label=\(name)", "drawing=on",
      "background.drawing=on", "background.color=\(configuration.background)",
      "label.color=\(configuration.foreground)",
      "icon.font=Apple Color Emoji:Regular:14.0",
      "icon.padding_left=6", "icon.padding_right=0",
      "label.padding_left=4", "label.padding_right=6",
    ])
  }

  func hide() {
    lock.lock()
    defer { lock.unlock() }
    guard visible else {
      return
    }
    run(["--remove", item])
    visible = false
  }

  private func run(_ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: configuration.executable)
    process.arguments = arguments
    // Bar failures must not interrupt authentication or contaminate PIN output.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return
    }
  }
}
