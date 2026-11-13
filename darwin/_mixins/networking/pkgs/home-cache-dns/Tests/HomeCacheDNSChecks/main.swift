import Foundation
import HomeCacheDNS

struct CheckFailure: Error {
  let message: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  guard try condition() else {
    throw CheckFailure(message: message)
  }
}

// Keep canceled results deliverable to exercise late callbacks during roaming.
final class FakeProbe: CacheProbing {
  var replies: [(Bool) -> Void] = []

  func check(completion: @escaping (Bool) -> Void) {
    replies.append(completion)
  }

  func cancel() {}

  func reply(_ reachable: Bool) {
    replies.removeFirst()(reachable)
  }
}

func testRoaming(_ root: URL) throws {
  let path = root.appendingPathComponent("roaming/cache.example.com")
  let probe = FakeProbe()
  var errors: [Error] = []
  let controller = ResolverController(
    probe: probe,
    resolver: ResolverFile(url: path, nameserver: "192.168.0.1"),
    reportError: { errors.append($0) }
  )
  let exists = { FileManager.default.fileExists(atPath: path.path) }

  controller.refresh()
  probe.reply(true)
  try expect(exists(), "home network must enable LAN DNS")
  let contents = try String(contentsOf: path)
  try expect(contents.contains("nameserver 192.168.0.1\n"), "resolver must use the configured DNS server")

  controller.refresh()
  probe.reply(false)
  try expect(!exists(), "leaving home must restore default DNS")

  controller.refresh()
  probe.reply(true)
  try expect(exists(), "a retry must recover after a failed probe")

  controller.refresh()
  controller.refresh()
  probe.replies.removeLast()(false)
  probe.reply(true)
  try expect(!exists(), "late success on the old network must not enable LAN DNS")

  controller.refresh()
  controller.refresh()
  probe.replies.removeLast()(true)
  probe.reply(false)
  try expect(exists(), "late failure on the old network must not disable LAN DNS")

  controller.refresh()
  controller.stop()
  probe.reply(true)
  try expect(!exists(), "shutdown must remove the override despite pending probes")
  try expect(errors.isEmpty, "roaming should not report errors")
}

func testRestartAndConfigurationChange(_ root: URL) throws {
  let path = root.appendingPathComponent("restart/cache.example.com")
  let oldResolver = ResolverFile(url: path, nameserver: "192.168.0.1")
  _ = try oldResolver.setEnabled(true)
  let newResolver = ResolverFile(url: path, nameserver: "192.168.1.1")
  _ = try newResolver.setEnabled(true)
  try expect(
    String(contentsOf: path).contains("nameserver 192.168.1.1\n"),
    "a new configuration must replace an owned override"
  )

  var errors: [Error] = []
  let controller = ResolverController(
    probe: FakeProbe(), resolver: newResolver, reportError: { errors.append($0) }
  )
  controller.stop()
  try expect(!FileManager.default.fileExists(atPath: path.path), "startup must remove stale state")
  try expect(errors.isEmpty, "stale state cleanup should succeed")
}

func testForeignResolverIsPreserved(_ root: URL) throws {
  let path = root.appendingPathComponent("operator-resolver")
  let contents = "nameserver 10.0.0.1\n"
  try contents.write(to: path, atomically: true, encoding: .utf8)
  let probe = FakeProbe()
  var errors: [Error] = []
  let controller = ResolverController(
    probe: probe,
    resolver: ResolverFile(url: path, nameserver: "192.168.0.1"),
    reportError: { errors.append($0) }
  )

  controller.refresh()
  probe.reply(true)
  try expect(!errors.isEmpty, "conflicting resolver must report an error")
  try expect(String(contentsOf: path) == contents, "operator resolver must not be overwritten")

  errors.removeAll()
  controller.stop()
  try expect(!errors.isEmpty, "conflicting resolver cleanup must report an error")
  try expect(String(contentsOf: path) == contents, "operator resolver must not be deleted")
}

func testWriteFailureIsReported(_ root: URL) throws {
  let parent = root.appendingPathComponent("not-a-directory")
  try Data().write(to: parent)
  let probe = FakeProbe()
  var errors: [Error] = []
  let controller = ResolverController(
    probe: probe,
    resolver: ResolverFile(url: parent.appendingPathComponent("cache.example.com"), nameserver: "192.168.0.1"),
    reportError: { errors.append($0) }
  )
  controller.refresh()
  probe.reply(true)
  try expect(!errors.isEmpty, "filesystem failures must be reported")
}

do {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer {
    try? FileManager.default.removeItem(at: root)
  }
  try testRoaming(root)
  try testRestartAndConfigurationChange(root)
  try testForeignResolverIsPreserved(root)
  try testWriteFailureIsReported(root)
  print("Home cache DNS behavior checks passed.")
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
