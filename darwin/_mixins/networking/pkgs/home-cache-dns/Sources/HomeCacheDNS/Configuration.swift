import Foundation
import Network

public struct Configuration: Decodable {
  public let hostname: String
  public let address: String
  public let nameserver: String
  public let interfaces: [String]

  public func validate() throws {
    let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count > 1,
      labels.allSatisfy({ label in
        label.range(of: #"^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$"#,
                    options: .regularExpression) != nil
      }),
      IPv4Address(address) != nil, IPv4Address(nameserver) != nil,
      !interfaces.isEmpty
    else {
      throw ConfigurationError.invalid
    }
  }
}

enum ConfigurationError: Error {
  case invalid
}
