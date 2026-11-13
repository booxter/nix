import Foundation
import Network
import Security

public final class LANProbe: CacheProbing {
  public var interfaces: [NWInterface] = []
  private let configuration: Configuration
  private var attempts: [TLSAttempt] = []

  public init(configuration: Configuration) {
    self.configuration = configuration
  }

  public func check(completion: @escaping (Bool) -> Void) {
    cancel()
    let candidates = interfaces.filter {
      configuration.interfaces.contains($0.name)
        && ($0.type == .wifi || $0.type == .wiredEthernet)
    }
    guard !candidates.isEmpty else {
      completion(false)
      return
    }

    var remaining = candidates.count
    var finished = false
    attempts = candidates.map { interface in
      TLSAttempt(configuration: configuration, interface: interface) { [weak self] reachable in
        guard !finished else {
          return
        }
        remaining -= 1
        if reachable || remaining == 0 {
          finished = true
          self?.cancel()
          completion(reachable)
        }
      }
    }
    for attempt in attempts {
      attempt.start()
    }
  }

  public func cancel() {
    for attempt in attempts {
      attempt.cancel()
    }
    attempts.removeAll()
  }
}

private final class TLSAttempt {
  private let connection: NWConnection
  private var completion: ((Bool) -> Void)?
  private var timeout: DispatchWorkItem?

  init(configuration: Configuration, interface: NWInterface, completion: @escaping (Bool) -> Void) {
    self.completion = completion
    let tls = NWProtocolTLS.Options()
    // Connect without DNS, but retain normal certificate and hostname checking.
    sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, configuration.hostname)
    sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    parameters.requiredInterface = interface
    connection = NWConnection(host: NWEndpoint.Host(configuration.address), port: 443, using: parameters)
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        self?.finish(true)
      case .failed:
        self?.finish(false)
      default:
        break
      }
    }
    let timeout = DispatchWorkItem { [weak self] in
      self?.finish(false)
    }
    self.timeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
    connection.start(queue: .main)
  }

  func cancel() {
    completion = nil
    timeout?.cancel()
    timeout = nil
    connection.stateUpdateHandler = nil
    connection.cancel()
  }

  private func finish(_ reachable: Bool) {
    let callback = completion
    cancel()
    callback?(reachable)
  }
}
