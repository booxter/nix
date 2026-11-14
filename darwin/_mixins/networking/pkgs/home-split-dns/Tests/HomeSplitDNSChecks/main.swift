import Foundation
import HomeSplitDNS

struct CheckFailure: Error {
  let message: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  guard try condition() else {
    throw CheckFailure(message: message)
  }
}

// Keep canceled results deliverable to exercise late callbacks during roaming.
final class FakeProbe: ServiceProbing {
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

func testIndependentServices(_ root: URL) throws {
  let firstPath = root.appendingPathComponent("first.example.com")
  let secondPath = root.appendingPathComponent("second.example.com")
  let firstProbe = FakeProbe()
  let secondProbe = FakeProbe()
  var errors: [Error] = []
  let first = ResolverController(
    probe: firstProbe,
    resolver: ResolverFile(url: firstPath, nameserver: "192.168.0.1"),
    reportError: { errors.append($0) }
  )
  let second = ResolverController(
    probe: secondProbe,
    resolver: ResolverFile(url: secondPath, nameserver: "192.168.0.1"),
    reportError: { errors.append($0) }
  )

  first.refresh()
  second.refresh()
  firstProbe.reply(true)
  secondProbe.reply(false)
  try expect(FileManager.default.fileExists(atPath: firstPath.path), "reachable service must use LAN DNS")
  try expect(!FileManager.default.fileExists(atPath: secondPath.path), "unreachable service must use default DNS")

  second.refresh()
  secondProbe.reply(true)
  first.refresh()
  firstProbe.reply(false)
  try expect(!FileManager.default.fileExists(atPath: firstPath.path), "failed service must lose its override")
  try expect(FileManager.default.fileExists(atPath: secondPath.path), "another service must remain on LAN DNS")
  second.stop()
  try expect(errors.isEmpty, "independent service transitions should succeed")
}

func testOwnedResolverCleanup(_ root: URL) throws {
  let directory = root.appendingPathComponent("cleanup")
  try expect(!ResolverFile.removeOwnedFiles(in: directory), "missing resolver directory needs no cleanup")
  let stale = directory.appendingPathComponent("removed.example.com")
  _ = try ResolverFile(url: stale, nameserver: "192.168.0.1").setEnabled(true)
  let foreign = directory.appendingPathComponent("operator.example.com")
  let foreignContents = "nameserver 10.0.0.1\n"
  try foreignContents.write(to: foreign, atomically: true, encoding: .utf8)
  let link = directory.appendingPathComponent("linked.example.com")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)

  try expect(ResolverFile.removeOwnedFiles(in: directory), "restart must remove owned files absent from inventory")
  try expect(!FileManager.default.fileExists(atPath: stale.path), "stale override must be removed")
  try expect(String(contentsOf: foreign) == foreignContents, "operator resolver must be preserved")
  try expect(link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true, "static symlink must be preserved")
  try expect(!ResolverFile.removeOwnedFiles(in: directory), "repeated cleanup must be a no-op")
}

func configuration(_ services: [[String: String]]) throws -> Configuration {
  let data = try JSONSerialization.data(withJSONObject: [
    "services": services,
    "nameserver": "192.168.0.1",
    "interfaces": ["en0"],
  ])
  return try JSONDecoder().decode(Configuration.self, from: data)
}

func testConfiguration() throws {
  try configuration([]).validate()
  try configuration([
    ["hostname": "cache.example.com", "address": "192.168.16.3"],
    ["hostname": "dash.example.com", "address": "192.168.20.2"],
  ]).validate()

  let invalidServices = [
    [["hostname": "../cache", "address": "192.168.16.3"]],
    [["hostname": "cache.example.com", "address": "invalid"]],
    [
      ["hostname": "cache.example.com", "address": "192.168.16.3"],
      ["hostname": "CACHE.example.com", "address": "192.168.20.2"],
    ],
  ]
  for services in invalidServices {
    var rejected = false
    do {
      try configuration(services).validate()
    } catch {
      rejected = true
    }
    try expect(rejected, "unsafe or duplicate service configuration must be rejected")
  }
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
  try testIndependentServices(root)
  try testOwnedResolverCleanup(root)
  try testConfiguration()
  print("Home split DNS behavior checks passed.")
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
