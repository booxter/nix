import Foundation
import Network

public struct Configuration: Decodable {
  public let services: [Service]
  public let nameserver: String
  public let interfaces: [String]

  public func validate() throws {
    guard IPv4Address(nameserver) != nil, !interfaces.isEmpty,
      Set(services.map { $0.hostname.lowercased() }).count == services.count
    else {
      throw ConfigurationError.invalid
    }
    for service in services {
      try service.validate()
    }
  }
}

public struct Service: Decodable {
  public let hostname: String
  public let address: String

  public func validate() throws {
    let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count > 1, hostname.utf8.count <= 253,
      labels.allSatisfy({ label in
        label.range(of: #"^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$"#,
                    options: .regularExpression) != nil
      }),
      IPv4Address(address) != nil
    else {
      throw ConfigurationError.invalid
    }
  }
}

enum ConfigurationError: Error {
  case invalid
}
