import Darwin
import Foundation
import HomeCacheDNS
import Network

func log(_ message: String) {
  FileHandle.standardError.write(Data("home-cache-dns: \(message)\n".utf8))
}

func fail(_ error: Error) -> Never {
  log(String(describing: error))
  exit(1)
}

let usage = "usage: home-cache-dns --config PATH [--check]"
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
  let probe = LANProbe(configuration: configuration)
  let monitor = NWPathMonitor()
  let checkOnly = arguments.count == 3

  if checkOnly {
    monitor.pathUpdateHandler = { path in
      monitor.cancel()
      probe.interfaces = path.availableInterfaces
      probe.check { reachable in
        print(reachable ? "Home cache reachable over LAN; TLS identity verified." : "Home cache unavailable over LAN.")
        exit(reachable ? 0 : 1)
      }
    }
    monitor.start(queue: .main)
    dispatchMain()
  }

  let resolver = ResolverFile(
    url: URL(fileURLWithPath: "/etc/resolver/\(configuration.hostname)"),
    nameserver: configuration.nameserver
  )
  let controller = ResolverController(
    probe: probe,
    resolver: resolver,
    reportError: { fail($0) },
    reportChange: { enabled in
      log(enabled ? "LAN DNS enabled for \(configuration.hostname)" : "using default DNS for \(configuration.hostname)")
    }
  )
  // Remove any override left by a crash or shutdown before the first probe.
  controller.stop()
  monitor.pathUpdateHandler = { path in
    probe.interfaces = path.availableInterfaces
    controller.refresh()
  }
  monitor.start(queue: .main)

  // Retry after transient outages even if the network path itself has not changed.
  let retry = DispatchSource.makeTimerSource(queue: .main)
  retry.schedule(deadline: .now() + 30, repeating: 30)
  retry.setEventHandler { controller.refresh() }
  retry.resume()

  let signals = [SIGTERM, SIGINT].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
      monitor.cancel()
      retry.cancel()
      controller.stop()
      exit(0)
    }
    source.resume()
    return source
  }
  withExtendedLifetime((monitor, controller, retry, signals)) {
    dispatchMain()
  }
} catch {
  fail(error)
}
