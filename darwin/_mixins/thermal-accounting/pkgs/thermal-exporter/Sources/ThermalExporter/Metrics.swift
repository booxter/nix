import Foundation

public struct MetricLabel: Equatable, Sendable {
  public let name: String
  public let value: String

  public init(_ name: String, _ value: String) {
    self.name = name
    self.value = value
  }
}

public struct MetricSample: Equatable, Sendable {
  public let name: String
  public let labels: [MetricLabel]
  public let value: Double
}

private struct MetricDefinition: Sendable {
  let name: String
  let help: String
}

public struct MetricRegistry: Sendable {
  private var definitions: [MetricDefinition] = []
  public private(set) var samples: [MetricSample] = []

  public init() {}

  public mutating func register(_ name: String, help: String) {
    precondition(!definitions.contains { $0.name == name }, "metric registered twice: \(name)")
    definitions.append(MetricDefinition(name: name, help: help))
  }

  public mutating func set(_ name: String, _ value: Double, labels: [MetricLabel] = []) {
    precondition(definitions.contains { $0.name == name }, "unregistered metric: \(name)")
    samples.append(MetricSample(name: name, labels: labels, value: value))
  }

  public func value(_ name: String, labels expected: [MetricLabel] = []) -> Double? {
    samples.first { $0.name == name && $0.labels == expected }?.value
  }

  public func render() -> String {
    var lines: [String] = []
    for definition in definitions {
      lines.append("# HELP \(definition.name) \(definition.help)")
      lines.append("# TYPE \(definition.name) gauge")
      for sample in samples where sample.name == definition.name {
        let labels = sample.labels.isEmpty
          ? ""
          : "{" + sample.labels.map { "\($0.name)=\"\(escape($0.value))\"" }.joined(separator: ",") + "}"
        lines.append("\(sample.name)\(labels) \(sample.value)")
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

private func escape(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\"", with: "\\\"")
}
