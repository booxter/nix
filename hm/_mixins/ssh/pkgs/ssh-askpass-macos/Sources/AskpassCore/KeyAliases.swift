import CryptoKit
import Foundation

public struct NamedPublicKey: Decodable {
  public let name: String
  public let label: String
  public let publicKey: String

  public init(name: String, label: String, publicKey: String) {
    self.name = name
    self.label = label
    self.publicKey = publicKey
  }
}

struct KeyAliases {
  private let fingerprintPattern = try! NSRegularExpression(pattern: "SHA256:[A-Za-z0-9+/]+")
  private let keysByFingerprint: [String: NamedPublicKey]

  init(publicKeys: [NamedPublicKey]) {
    var keys: [String: NamedPublicKey] = [:]
    for key in publicKeys {
      let fields = key.publicKey.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
        continue
      }

      // OpenSSH fingerprints hash the decoded key blob, excluding its comment.
      let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
      let fingerprint = "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
      keys[fingerprint] = key
    }
    keysByFingerprint = keys
  }

  func key(for prompt: String) -> NamedPublicKey? {
    let fingerprints = fingerprintPattern.matches(
      in: prompt, range: NSRange(prompt.startIndex..., in: prompt)
    )
    return fingerprints.compactMap { match -> NamedPublicKey? in
      guard let range = Range(match.range, in: prompt) else {
        return nil
      }
      return keysByFingerprint[String(prompt[range])]
    }.first
  }
}
