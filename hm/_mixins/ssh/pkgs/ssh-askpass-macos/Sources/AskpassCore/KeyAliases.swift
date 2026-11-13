import CryptoKit
import Foundation

struct KeyAliases {
  private let fingerprintPattern = try! NSRegularExpression(pattern: "SHA256:[A-Za-z0-9+/]+")
  private let namesByFingerprint: [String: String]

  init(publicKeys: [String: String]) {
    var names: [String: String] = [:]
    for (name, publicKey) in publicKeys {
      let fields = publicKey.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
        continue
      }

      // OpenSSH fingerprints hash the decoded key blob, excluding its comment.
      let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
      let fingerprint = "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
      names[fingerprint] = name
    }
    namesByFingerprint = names
  }

  func decorate(_ prompt: String) -> String {
    let fingerprints = fingerprintPattern.matches(
      in: prompt, range: NSRange(prompt.startIndex..., in: prompt)
    )
    let names = fingerprints.compactMap { match -> String? in
      guard let range = Range(match.range, in: prompt) else {
        return nil
      }
      return namesByFingerprint[String(prompt[range])]
    }
    guard !names.isEmpty else {
      return prompt
    }
    return names.joined(separator: "\n") + "\n\n" + prompt
  }
}
