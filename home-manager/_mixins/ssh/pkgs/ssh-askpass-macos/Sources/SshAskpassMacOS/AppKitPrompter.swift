import AppKit
import AskpassCore

final class AppKitPrompter: Prompting {
  func confirm(prompt: String) -> Bool {
    let alert = makeAlert(prompt: prompt)
    alert.addButton(withTitle: "Yes")
    alert.addButton(withTitle: "No")
    return alert.runModal() == .alertFirstButtonReturn
  }

  func readSecret(prompt: String) -> String? {
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    let alert = makeAlert(prompt: prompt)
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else {
      return nil
    }
    return field.stringValue
  }

  private func makeAlert(prompt: String) -> NSAlert {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "OpenSSH authentication"
    alert.informativeText = prompt
    return alert
  }
}
