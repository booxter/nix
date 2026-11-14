import Darwin
import Foundation
import HomeSplitDNS
import Network
import SystemConfiguration

func log(_ message: String) {
  FileHandle.standardError.write(Data("home-split-dns: \(message)\n".utf8))
}

func fail(_ error: Error) -> Never {
  log(String(describing: error))
  exit(1)
}

func notifyResolverChange() {
  // Ask configd to rebuild DNS configuration after an /etc/resolver change.
  // The work Mac initially omitted the override from its active DNS configuration.
  guard let store = SCDynamicStoreCreate(nil, "home-split-dns" as CFString, nil, nil),
    SCDynamicStoreNotifyValue(store, "State:/Network/MulticastDNS" as CFString)
  else {
    fail(NSError(domain: NSOSStatusErrorDomain, code: Int(SCError())))
  }
}

struct ServiceSession {
  let hostname: String
  let probe: LANProbe
  let controller: ResolverController

  init(service: Service, configuration: Configuration, directory: URL) {
    hostname = service.hostname
    probe = LANProbe(service: service, interfaces: configuration.interfaces)
    controller = ResolverController(
      probe: probe,
      resolver: ResolverFile(
        url: directory.appendingPathComponent(service.hostname),
        nameserver: configuration.nameserver
      ),
      reportError: { log("\(service.hostname): \($0)") },
      reportChange: { enabled in
        notifyResolverChange()
        log(enabled ? "LAN DNS enabled for \(service.hostname)" : "using default DNS for \(service.hostname)")
      }
    )
  }
}

func checkServices(_ sessions: [ServiceSession], monitor: NWPathMonitor) -> Never {
  guard !sessions.isEmpty else {
    exit(0)
  }
  monitor.pathUpdateHandler = { path in
    monitor.cancel()
    var remaining = sessions.count
    var allReachable = true
    for session in sessions {
      session.probe.interfaces = path.availableInterfaces
      session.probe.check { reachable in
        print("\(session.hostname): \(reachable ? "LAN TLS identity verified" : "unavailable over LAN")")
        allReachable = allReachable && reachable
        remaining -= 1
        if remaining == 0 {
          exit(allReachable ? 0 : 1)
        }
      }
    }
  }
  monitor.start(queue: .main)
  dispatchMain()
}

func runDaemon(_ sessions: [ServiceSession], monitor: NWPathMonitor, directory: URL) throws -> Never {
  // Also remove overrides for services no longer present in the inventory.
  if try ResolverFile.removeOwnedFiles(in: directory) {
    notifyResolverChange()
  }
  monitor.pathUpdateHandler = { path in
    for session in sessions {
      session.probe.interfaces = path.availableInterfaces
      session.controller.refresh()
    }
  }
  monitor.start(queue: .main)

  // Retry transient outages even if the network path itself has not changed.
  let retry = DispatchSource.makeTimerSource(queue: .main)
  retry.schedule(deadline: .now() + 30, repeating: 30)
  retry.setEventHandler {
    for session in sessions {
      session.controller.refresh()
    }
  }
  retry.resume()

  let signals = [SIGTERM, SIGINT].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
      monitor.cancel()
      retry.cancel()
      for session in sessions {
        session.controller.stop()
      }
      exit(0)
    }
    source.resume()
    return source
  }
  withExtendedLifetime((sessions, retry, signals)) {
    dispatchMain()
  }
}

let usage = "usage: home-split-dns --config PATH [--check]"
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
  print(usage)
  exit(0)
}
guard (arguments.count == 2 || arguments.count == 3), arguments[0] == "--config",
  arguments.count == 2 || arguments[2] == "--check"
else {
  log(usage)
  exit(1)
}

do {
  let configuration = try JSONDecoder().decode(
    Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1]))
  )
  try configuration.validate()
  let directory = URL(fileURLWithPath: "/etc/resolver")
  let sessions = configuration.services.map {
    ServiceSession(service: $0, configuration: configuration, directory: directory)
  }
  let monitor = NWPathMonitor()
  if arguments.count == 3 {
    checkServices(sessions, monitor: monitor)
  }
  try runDaemon(sessions, monitor: monitor, directory: directory)
} catch {
  fail(error)
}
