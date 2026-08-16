import Foundation
import ServiceManagement
import SystemConfiguration

public struct ExpectedJob: Codable, Equatable, Sendable {
  public let name: String

  public init(name: String) {
    self.name = name
  }
}

public enum LaunchdDomain: String, Codable, Equatable, Sendable {
  case system
  case user
}

public struct ExportConfiguration: Codable, Equatable, Sendable {
  public let domain: LaunchdDomain
  public let jobs: [ExpectedJob]
  public let monitoredUser: String?

  public init(domain: LaunchdDomain, jobs: [ExpectedJob], monitoredUser: String? = nil) {
    self.domain = domain
    self.jobs = jobs
    self.monitoredUser = monitoredUser
  }
}

public struct LaunchdJob: Equatable, Sendable {
  public let name: String
  public let pid: Int?
  public let rawLastExitStatus: Int

  public init(name: String, pid: Int?, rawLastExitStatus: Int) {
    self.name = name
    self.pid = pid
    self.rawLastExitStatus = rawLastExitStatus
  }

  public var running: Bool { pid != nil }
  public var lastExitCode: Int { decodeWaitStatus(rawLastExitStatus) }
}

public func decodeWaitStatus(_ status: Int) -> Int {
  let signal = status & 0x7f
  return signal == 0 ? (status >> 8) & 0xff : -signal
}

public protocol LaunchdJobLoading: Sendable {
  func jobs(in domain: LaunchdDomain, named names: Set<String>) throws -> [LaunchdJob]
}

public protocol ConsoleUserLoading: Sendable {
  func consoleUser() -> String?
}

public struct SystemConfigurationConsoleUserLoader: ConsoleUserLoading {
  public init() {}

  public func consoleUser() -> String? {
    SCDynamicStoreCopyConsoleUser(nil, nil, nil) as String?
  }
}

public enum LaunchdJobLoaderError: Error, CustomStringConvertible {
  case unavailable(LaunchdDomain)
  case missingLastExitStatus(String)

  public var description: String {
    switch self {
    case let .unavailable(domain):
      return "ServiceManagement did not return \(domain.rawValue) launchd jobs"
    case let .missingLastExitStatus(name):
      return "ServiceManagement omitted LastExitStatus for \(name)"
    }
  }
}

public struct ServiceManagementJobLoader: LaunchdJobLoading {
  public init() {}

  public func jobs(in domain: LaunchdDomain, named names: Set<String>) throws -> [LaunchdJob] {
    let nativeDomain = switch domain {
    case .system: kSMDomainSystemLaunchd
    case .user: kSMDomainUserLaunchd
    }
    guard let result = SMCopyAllJobDictionaries(nativeDomain) else {
      throw LaunchdJobLoaderError.unavailable(domain)
    }
    let dictionaries = result.takeRetainedValue() as NSArray
    return try dictionaries.compactMap { value in
      guard let dictionary = value as? [String: Any],
        let name = dictionary["Label"] as? String,
        names.contains(name)
      else {
        return nil
      }
      guard let rawLastExitStatus = (dictionary["LastExitStatus"] as? NSNumber)?.intValue else {
        throw LaunchdJobLoaderError.missingLastExitStatus(name)
      }
      return LaunchdJob(
        name: name,
        pid: (dictionary["PID"] as? NSNumber)?.intValue,
        rawLastExitStatus: rawLastExitStatus
      )
    }
  }
}

public enum ExportServiceError: Error, CustomStringConvertible {
  case duplicateJob(String)
  case duplicateNativeJob(String)

  public var description: String {
    switch self {
    case let .duplicateJob(name):
      return "duplicate expected launchd job: \(name)"
    case let .duplicateNativeJob(name):
      return "ServiceManagement returned duplicate launchd job: \(name)"
    }
  }
}

public struct LaunchdExportService: Sendable {
  public let configurationURL: URL
  public let outputURL: URL
  public let loader: any LaunchdJobLoading
  public let consoleUserLoader: any ConsoleUserLoading
  public let now: @Sendable () -> Date

  public init(
    configurationURL: URL,
    outputURL: URL,
    loader: any LaunchdJobLoading = ServiceManagementJobLoader(),
    consoleUserLoader: any ConsoleUserLoading = SystemConfigurationConsoleUserLoader(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configurationURL = configurationURL
    self.outputURL = outputURL
    self.loader = loader
    self.consoleUserLoader = consoleUserLoader
    self.now = now
  }

  public func run() throws {
    let configuration = try JSONDecoder().decode(
      ExportConfiguration.self,
      from: Data(contentsOf: configurationURL)
    )
    let names = Set(configuration.jobs.map(\.name))
    guard names.count == configuration.jobs.count else {
      let grouped = Dictionary(grouping: configuration.jobs.map(\.name), by: { $0 })
      throw ExportServiceError.duplicateJob(grouped.first { $0.value.count > 1 }!.key)
    }

    let timestamp = now().timeIntervalSince1970
    let domainActivity = configuration.monitoredUser.map { monitoredUser in
      [LaunchdDomain.system: true, LaunchdDomain.user: consoleUserLoader.consoleUser() == monitoredUser]
    } ?? [:]
    do {
      let jobs = try loader.jobs(in: configuration.domain, named: names)
      let jobsByName = Dictionary(grouping: jobs, by: \.name)
      if let duplicate = jobsByName.first(where: { $0.value.count > 1 }) {
        throw ExportServiceError.duplicateNativeJob(duplicate.key)
      }
      try write(
        renderMetrics(
          domain: configuration.domain,
          expected: configuration.jobs,
          actual: jobs,
          timestamp: timestamp,
          success: true,
          domainActivity: domainActivity
        )
      )
    } catch {
      try write(
        renderMetrics(
          domain: configuration.domain,
          expected: [],
          actual: [],
          timestamp: timestamp,
          success: false,
          domainActivity: domainActivity
        )
      )
      throw error
    }
  }

  private func write(_ text: String) throws {
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: outputURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outputURL.path)
  }
}

public func renderMetrics(
  domain: LaunchdDomain,
  expected: [ExpectedJob],
  actual: [LaunchdJob],
  timestamp: TimeInterval,
  success: Bool,
  domainActivity: [LaunchdDomain: Bool] = [:]
) -> String {
  let prefix = "host_observability_darwin_launchd_"
  var lines = [
    "# HELP \(prefix)collect_success Whether native launchd state collection succeeded.",
    "# TYPE \(prefix)collect_success gauge",
    "\(prefix)collect_success{domain=\"\(domain.rawValue)\"} \(success ? 1 : 0)",
    "# HELP \(prefix)sample_timestamp_seconds Unix timestamp of the latest launchd collection attempt.",
    "# TYPE \(prefix)sample_timestamp_seconds gauge",
    "\(prefix)sample_timestamp_seconds{domain=\"\(domain.rawValue)\"} \(timestamp)",
    "# HELP \(prefix)domain_active Whether the configured launchd domain should currently be monitored.",
    "# TYPE \(prefix)domain_active gauge",
  ]
  for activeDomain in [LaunchdDomain.system, LaunchdDomain.user] {
    if let active = domainActivity[activeDomain] {
      lines.append("\(prefix)domain_active{domain=\"\(activeDomain.rawValue)\"} \(active ? 1 : 0)")
    }
  }
  lines += [
    "# HELP \(prefix)job_loaded Whether an expected launchd job is loaded.",
    "# TYPE \(prefix)job_loaded gauge",
  ]
  let actualByName = Dictionary(actual.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
  for job in expected.sorted(by: { $0.name < $1.name }) {
    let labels = #"{domain="\#(domain.rawValue)",name="\#(escapeLabel(job.name))"}"#
    lines.append("\(prefix)job_loaded\(labels) \(actualByName[job.name] == nil ? 0 : 1)")
  }
  lines += [
    "# HELP \(prefix)job_running Whether a loaded launchd job currently has a process.",
    "# TYPE \(prefix)job_running gauge",
  ]
  for job in actual.sorted(by: { $0.name < $1.name }) {
    let labels = #"{domain="\#(domain.rawValue)",name="\#(escapeLabel(job.name))"}"#
    lines.append("\(prefix)job_running\(labels) \(job.running ? 1 : 0)")
  }
  lines += [
    "# HELP \(prefix)job_last_exit_code Decoded exit code, or negative terminating signal, from launchd.",
    "# TYPE \(prefix)job_last_exit_code gauge",
  ]
  for job in actual.sorted(by: { $0.name < $1.name }) {
    let labels = #"{domain="\#(domain.rawValue)",name="\#(escapeLabel(job.name))"}"#
    lines.append("\(prefix)job_last_exit_code\(labels) \(job.lastExitCode)")
  }
  return lines.joined(separator: "\n") + "\n"
}

private func escapeLabel(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\"", with: "\\\"")
}
