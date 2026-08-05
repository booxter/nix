import Foundation

public struct CommandResult: Sendable {
  public let status: Int32
  public let output: Data

  public init(status: Int32, output: Data) {
    self.status = status
    self.output = output
  }

  public var succeeded: Bool { status == 0 }
  public var text: String { String(decoding: output, as: UTF8.self) }
}

public protocol CommandRunning: Sendable {
  func run(_ executable: String, arguments: [String], mergeStandardError: Bool) throws -> CommandResult
}

public struct ProcessRunner: CommandRunning {
  public init() {}

  public func run(
    _ executable: String,
    arguments: [String],
    mergeStandardError: Bool
  ) throws -> CommandResult {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = mergeStandardError ? output : FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, output: data)
  }
}

public struct ThermalExporterService: Sendable {
  public let ismcPath: String
  public let textfileDirectory: URL
  public let stateDirectory: URL
  public let runner: any CommandRunning
  public let now: @Sendable () -> Date

  public init(
    ismcPath: String,
    textfileDirectory: URL = URL(fileURLWithPath: "/var/lib/prometheus-node-exporter-textfile"),
    stateDirectory: URL = URL(fileURLWithPath: "/var/lib/observability-thermal"),
    runner: any CommandRunning = ProcessRunner(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.ismcPath = ismcPath
    self.textfileDirectory = textfileDirectory
    self.stateDirectory = stateDirectory
    self.runner = runner
    self.now = now
  }

  public func run() throws {
    try ensureDirectory(textfileDirectory)
    try ensureDirectory(stateDirectory)
    let pmset = try runner.run("/usr/bin/pmset", arguments: ["-g", "therm"], mergeStandardError: false)
    let ismc = try runner.run(ismcPath, arguments: ["temp", "-o", "json"], mergeStandardError: true)
    let powermetrics = try runner.run(
      "/usr/bin/powermetrics",
      arguments: ["-n", "1", "-i", "500", "--samplers", "cpu_power,thermal"],
      mergeStandardError: true
    )

    try atomicWrite(pmset.output, to: stateDirectory.appendingPathComponent("latest-pmset-therm.txt"))
    try atomicWrite(
      powermetrics.output,
      to: stateDirectory.appendingPathComponent("latest-powermetrics.txt")
    )
    try atomicWrite(ismc.output, to: stateDirectory.appendingPathComponent("latest-ismc-temp.json"))

    let snapshot = ThermalSnapshot(
      timestamp: now(),
      pmset: pmset.text,
      powermetrics: powermetrics.text,
      powermetricsSucceeded: powermetrics.succeeded,
      ismc: ismc.output,
      ismcSucceeded: ismc.succeeded
    )
    let rendered = try ThermalCollector.collect(snapshot).render().data(using: .utf8)!
    try atomicWrite(rendered, to: textfileDirectory.appendingPathComponent("thermal.prom"))
  }
}

private func ensureDirectory(_ url: URL) throws {
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func atomicWrite(_ data: Data, to url: URL) throws {
  try data.write(to: url, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
}
