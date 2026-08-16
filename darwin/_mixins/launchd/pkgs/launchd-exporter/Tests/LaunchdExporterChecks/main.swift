import Foundation
import LaunchdExporter

enum CheckFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
    case let .failed(message): message
    }
  }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw CheckFailure.failed(message) }
}

struct FakeLoader: LaunchdJobLoading {
  let jobs: [LaunchdJob]
  let error: CheckFailure?

  func jobs(in domain: LaunchdDomain, named names: Set<String>) throws -> [LaunchdJob] {
    if let error { throw error }
    return jobs.filter { names.contains($0.name) }
  }
}

struct FakeConsoleUserLoader: ConsoleUserLoading {
  let user: String?

  func consoleUser() -> String? { user }
}

func testWaitStatusDecoding() throws {
  try expect(decodeWaitStatus(0) == 0, "zero exit")
  try expect(decodeWaitStatus(1 << 8) == 1, "nonzero exit")
  try expect(decodeWaitStatus(78 << 8) == 78, "EX_CONFIG exit")
  try expect(decodeWaitStatus(15) == -15, "signal exit")
}

func testMetricsDescribeExpectedJobs() throws {
  let metrics = renderMetrics(
    domain: .system,
    expected: [ExpectedJob(name: "org.nixos.running"), ExpectedJob(name: "org.nixos.missing")],
    actual: [LaunchdJob(name: "org.nixos.running", pid: 42, rawLastExitStatus: 1 << 8)],
    timestamp: 1234,
    success: true
  )
  try expect(metrics.contains(#"launchd_collect_success{domain="system"} 1"#), "collection success")
  try expect(
    metrics.contains(#"launchd_sample_timestamp_seconds{domain="system"} 1234.0"#),
    "sample timestamp"
  )
  try expect(
    metrics.contains(#"launchd_job_loaded{domain="system",name="org.nixos.missing"} 0"#),
    "missing job"
  )
  try expect(
    metrics.contains(#"launchd_job_running{domain="system",name="org.nixos.running"} 1"#),
    "running job"
  )
  try expect(
    metrics.contains(#"launchd_job_last_exit_code{domain="system",name="org.nixos.running"} 1"#),
    "decoded exit"
  )
}

func testServicePublishesFailureHealth() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let configuration = root.appendingPathComponent("config.json")
  try JSONEncoder().encode(
    ExportConfiguration(domain: .user, jobs: [ExpectedJob(name: "org.nixos.example")])
  ).write(to: configuration)
  let output = root.appendingPathComponent("textfiles/launchd-state.prom")
  let service = LaunchdExportService(
    configurationURL: configuration,
    outputURL: output,
    loader: FakeLoader(jobs: [], error: .failed("native API failed")),
    now: { Date(timeIntervalSince1970: 100) }
  )
  do {
    try service.run()
    throw CheckFailure.failed("service should propagate collection failure")
  } catch CheckFailure.failed(let message) {
    try expect(message == "native API failed", "unexpected propagated failure")
  }
  let metrics = try String(contentsOf: output, encoding: .utf8)
  try expect(
    metrics.contains(#"launchd_collect_success{domain="user"} 0"#),
    "failure health metric"
  )
  try expect(
    metrics.contains(#"launchd_sample_timestamp_seconds{domain="user"} 100.0"#),
    "failure timestamp"
  )
}

func testServicePublishesDomainActivity() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let configuration = root.appendingPathComponent("config.json")
  try JSONEncoder().encode(
    ExportConfiguration(domain: .system, jobs: [], monitoredUser: "primary")
  ).write(to: configuration)
  let output = root.appendingPathComponent("launchd-state.prom")
  try LaunchdExportService(
    configurationURL: configuration,
    outputURL: output,
    loader: FakeLoader(jobs: [], error: nil),
    consoleUserLoader: FakeConsoleUserLoader(user: "primary")
  ).run()
  let metrics = try String(contentsOf: output, encoding: .utf8)
  try expect(
    metrics.contains(#"launchd_domain_active{domain="system"} 1"#),
    "system domain activity"
  )
  try expect(
    metrics.contains(#"launchd_domain_active{domain="user"} 1"#),
    "user domain activity"
  )

  try LaunchdExportService(
    configurationURL: configuration,
    outputURL: output,
    loader: FakeLoader(jobs: [], error: nil),
    consoleUserLoader: FakeConsoleUserLoader(user: nil)
  ).run()
  let loggedOutMetrics = try String(contentsOf: output, encoding: .utf8)
  try expect(
    loggedOutMetrics.contains(#"launchd_domain_active{domain="user"} 0"#),
    "logged-out user domain activity"
  )
}

do {
  try testWaitStatusDecoding()
  try testMetricsDescribeExpectedJobs()
  try testServicePublishesFailureHealth()
  try testServicePublishesDomainActivity()
} catch {
  FileHandle.standardError.write(Data("LaunchdExporterChecks: \(error)\n".utf8))
  exit(1)
}
