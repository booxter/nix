import Foundation
import ThermalExporter

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

func sensorJSON() -> Data {
  Data(
    """
    {
      "CPU Performance Core 1":{"key":"Tp01","type":"ioft","quantity":81.5,"unit":"°C"},
      "CPU Efficiency Core 1":{"key":"Te01","type":"ioft","quantity":70,"unit":"°C"},
      "NAND CH0 temp":{"key":"TN01","type":"ioft","quantity":55,"unit":"°C"},
      "Invalid":{"key":"BAD","type":"ioft","quantity":9000,"unit":"°C"},
      "Voltage":{"key":"V001","type":"flt","quantity":12,"unit":"V"}
    }
    """.utf8
  )
}

func testStructuredCollection() throws {
  let snapshot = ThermalSnapshot(
    timestamp: Date(timeIntervalSince1970: 1234),
    pmset: "Thermal Warning Level: 2\nPerformance Warning Level: 1\nCPU Power Status: 3\n",
    powermetrics: "CPU Power: 2500 mW\nGPU Power: 3.5 W\n",
    powermetricsSucceeded: true,
    ismc: sensorJSON(),
    ismcSucceeded: true
  )
  let metrics = try ThermalCollector.collect(snapshot)
  try expect(metrics.value("host_observability_darwin_thermal_warning_level") == 2, "thermal level")
  try expect(
    metrics.value(
      "host_observability_darwin_power_watts",
      labels: [.init("domain", "cpu")]
    ) == 2.5,
    "CPU milliwatts"
  )
  try expect(
    metrics.value(
      "host_observability_darwin_temperature_group_max_celsius",
      labels: [.init("group", "cpu")]
    ) == 81.5,
    "CPU group maximum"
  )
  try expect(
    metrics.value(
      "host_observability_darwin_temperature_group_max_celsius",
      labels: [.init("group", "storage")]
    ) == 55,
    "storage group maximum"
  )
  try expect(metrics.value("host_observability_darwin_temperature_max_celsius") == 81.5, "global maximum")
  let sensors = metrics.samples.filter { $0.name == "host_observability_darwin_temperature_celsius" }
  try expect(sensors.count == 3, "invalid sensors must be discarded")
}

struct InMemoryRunner: CommandRunning {
  let results: [String: CommandResult]

  func run(_ executable: String, arguments _: [String], mergeStandardError _: Bool) throws -> CommandResult {
    guard let result = results[executable] else {
      throw CheckFailure.failed("unexpected executable \(executable)")
    }
    return result
  }
}

func testServicePublishesStateAndMetrics() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let runner = InMemoryRunner(results: [
    "/usr/bin/pmset": CommandResult(status: 0, output: Data("Thermal Warning Level: 1\n".utf8)),
    "/ismc": CommandResult(status: 0, output: sensorJSON()),
    "/usr/bin/powermetrics": CommandResult(status: 0, output: Data("ANE Power: 500 mW\n".utf8)),
  ])
  let service = ThermalExporterService(
    ismcPath: "/ismc",
    textfileDirectory: root.appendingPathComponent("textfiles"),
    stateDirectory: root.appendingPathComponent("state"),
    runner: runner,
    now: { Date(timeIntervalSince1970: 100) }
  )

  try service.run()

  let state = root.appendingPathComponent("state")
  let latestPMSet = try String(
    contentsOf: state.appendingPathComponent("latest-pmset-therm.txt"),
    encoding: .utf8
  )
  try expect(
    latestPMSet == "Thermal Warning Level: 1\n",
    "pmset state"
  )
  try expect(
    FileManager.default.fileExists(atPath: root.appendingPathComponent("textfiles/thermal.prom").path),
    "metrics file"
  )
  let attributes = try FileManager.default.attributesOfItem(
    atPath: root.appendingPathComponent("textfiles/thermal.prom").path
  )
  try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644, "metrics mode")
}

do {
  try testStructuredCollection()
  try testServicePublishesStateAndMetrics()
} catch {
  FileHandle.standardError.write(Data("ThermalExporterChecks: \(error)\n".utf8))
  exit(1)
}
